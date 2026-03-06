import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart'; // for compute
import 'package:flutter_dotenv/flutter_dotenv.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: WasteScannerScreen(),
    ),
  );
}

enum ScanMode { barcode, ai } // กำหนดโหมดการทำงาน

class WasteScannerScreen extends StatefulWidget {
  const WasteScannerScreen({super.key});
  @override
  State<WasteScannerScreen> createState() => _WasteScannerScreenState();
}

class _WasteScannerScreenState extends State<WasteScannerScreen> {
  // ---------------- CONFIG ----------------
  String apiKey = dotenv.env['GOOGLE_VISION_API_KEY'] ?? 'ไม่พบ API Key';
  final MobileScannerController cameraController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    returnImage: false,
  );
  // ---------------- STATE ----------------
  ScanMode currentMode = ScanMode.barcode;
  String rTitle = "", rDetail = "", rScore = ""; // ตัวแปรเก็บผลลัพธ์
  Color rColor = Colors.white; // สีของธีมผลลัพธ์
  IconData rIcon = Icons.info;
  bool isScanning = true, isLoading = false, isTorchOn = false;
  XFile? _imageFile;
  // AI Multiple Results
  List<Map<String, dynamic>> aiResults = [];
  int currentResultIndex = 0;
  // ---------------- cache / rate limit ----------------
  final Map<String, Map<String, dynamic>> _barcodeCache = {};
  DateTime? _lastBarcodeRequestAt;
  final Duration _barcodeCooldown = const Duration(seconds: 2);
  final int _maxRetries = 2;

  // ---------------- SYSTEM LOGIC ----------------
  // รีเซ็ตค่าทั้งหมดเพื่อเริ่มสแกนใหม่
  void _reset({bool full = false}) => setState(() {
    isScanning = true;
    isLoading = false;
    rTitle = "";
    aiResults = [];
    currentResultIndex = 0;
    if (full) _imageFile = null;
  });

  // สลับโหมดและเคลียร์ค่า
  void _switchMode(ScanMode mode) {
    setState(() => currentMode = mode);
    _reset(full: true);
  }

  // ฟังก์ชันช่วยอัปเดตผลลัพธ์หน้าจอ (เพิ่มการปิด Loading อัตโนมัติเมื่อได้ผลลัพธ์)
  void _setResult(String t, String d, String s, Color c, IconData i) =>
      setState(() {
        rTitle = t;
        rDetail = d;
        rScore = s;
        rColor = c;
        rIcon = i;
        isLoading = false;
      });

  @override
  void dispose() {
    cameraController.dispose();
    super.dispose();
  }

  // ---------------- 1. BARCODE LOGIC (เชื่อม API) ----------------
  Future<void> onBarcodeDetect(BarcodeCapture capture) async {
    // ถ้าไม่อยู่โหมดนี้ หรือมีผลแล้ว ให้ข้ามไป
    if (currentMode != ScanMode.barcode || !isScanning || rTitle.isNotEmpty)
      return;

    if (capture.barcodes.isNotEmpty &&
        capture.barcodes.first.rawValue != null) {
      final code = capture.barcodes.first.rawValue!;
      // rate-limit: ignore if last request was too recent
      if (_lastBarcodeRequestAt != null &&
          DateTime.now().difference(_lastBarcodeRequestAt!) < _barcodeCooldown)
        return;
      _lastBarcodeRequestAt = DateTime.now();

      // ถ้ามี cache ให้ใช้เลย
      if (_barcodeCache.containsKey(code)) {
        final cached = _barcodeCache[code]!;
        _setResult(
          cached['title'] ?? '',
          cached['detail'] ?? '',
          cached['score'] ?? '',
          cached['color'] ?? Colors.grey,
          cached['icon'] ?? Icons.info,
        );
        return;
      }

      // หยุดสแกนและแสดง Loading ทันทีเพื่อรอการเชื่อมต่อ
      if (mounted)
        setState(() {
          isScanning = false;
          isLoading = true;
        });

      try {
        // ยิง HTTP GET Request ไปหา OpenFoodFacts API
        final url = Uri.parse(
          'https://world.openfoodfacts.org/api/v0/product/$code.json',
        );
        // retry + timeout
        http.Response? response;
        for (int attempt = 0; attempt <= _maxRetries; attempt++) {
          try {
            response = await http.get(url).timeout(const Duration(seconds: 10));
            break;
          } catch (e) {
            if (attempt == _maxRetries) rethrow;
            await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
          }
        }

        if (response != null && response.statusCode == 200) {
          final data = json.decode(response.body);

          if (data['status'] == 1) {
            final product = data['product'];
            String productName =
                product['product_name_th'] ??
                product['product_name'] ??
                'ไม่ทราบชื่อสินค้า';

            // ดึงข้อมูลและตัดคำว่า en: หรือ th: ที่ติดมากับ API ทิ้ง
            String packaging =
                product['packaging']
                    ?.toString()
                    .replaceAll('en:', '')
                    .replaceAll('th:', '')
                    .trim() ??
                '';

            Color binColor = Colors.blue;
            IconData binIcon = Icons.delete_outline;
            String instruction = "ทิ้งถังน้ำเงิน (ขยะทั่วไป)";

            // 🧠 ตรรกะคาดเดาวัสดุ (Fallback Logic)
            // ก่อนอื่นขอทดลองดูจาก Barcode Range (GS1 Standard)
            String materialGuess = _classifyByBarcodeRange(code);

            if (packaging.isEmpty || packaging == 'null') {
              if (materialGuess.isNotEmpty) {
                packaging = 'วิเคราะห์จากรหัส: $materialGuess';
              }

              String nameLower = productName.toLowerCase();
              if (nameLower.contains('coca cola') ||
                  nameLower.contains('coke') ||
                  nameLower.contains('pepsi') ||
                  nameLower.contains('sprite') ||
                  nameLower.contains('est')) {
                if (packaging == 'null') packaging = 'ขวดพลาสติก/กระป๋อง';
                binColor = Colors.yellow;
                binIcon = Icons.recycling;
                instruction = "ทิ้งถังเหลือง (รีไซเคิล)";
              } else if (nameLower.contains('water') ||
                  nameLower.contains('น้ำดื่ม') ||
                  nameLower.contains('namthip') ||
                  nameLower.contains('crystal')) {
                if (packaging == 'null') packaging = 'ขวดพลาสติก PET';
                binColor = Colors.yellow;
                binIcon = Icons.recycling;
                instruction = "ทิ้งถังเหลือง (รีไซเคิล)";
              } else if (nameLower.contains('lay') ||
                  nameLower.contains('snack') ||
                  nameLower.contains('ขนม')) {
                if (packaging == 'null') packaging = 'ซองฟอยล์/พลาสติก';
                binColor = Colors.blue;
                binIcon = Icons.fastfood;
                instruction = "ทิ้งถังน้ำเงิน (ขยะทั่วไป)";
              } else {
                if (packaging == 'null') {
                  packaging = materialGuess.isNotEmpty
                      ? 'วิเคราะห์จากรหัส: $materialGuess'
                      : 'ไม่มีข้อมูลวัสดุในระบบ API';
                }
                instruction = "ทิ้งถังเหลือง หรือเช็คข้างบรรจุภัณฑ์";
                // ตรวจสอบวัสดุที่ได้จากการวิเคราะห์
                if (materialGuess.contains('พลาสติก') ||
                    materialGuess.contains('ขวด') ||
                    materialGuess.contains('กล่อง')) {
                  binColor = Colors.yellow;
                  binIcon = Icons.recycling;
                  instruction = "ทิ้งถังเหลือง (รีไซเคิล)";
                }
              }
            } else {
              // ถ้า API มีข้อมูลวัสดุมาให้ ก็เช็คคำศัพท์
              String pkgLower = packaging.toLowerCase();
              if (pkgLower.contains('plastic') ||
                  pkgLower.contains('pet') ||
                  pkgLower.contains('พลาสติก')) {
                binColor = Colors.yellow;
                binIcon = Icons.recycling;
                instruction = "ทิ้งถังเหลือง (รีไซเคิล)";
              } else if (pkgLower.contains('glass') ||
                  pkgLower.contains('แก้ว') ||
                  pkgLower.contains('bottle glass')) {
                binColor = Colors.yellow;
                binIcon = Icons.recycling;
                instruction = "ทิ้งถังเหลือง (รีไซเคิล)";
              } else if (pkgLower.contains('aluminium') ||
                  pkgLower.contains('can') ||
                  pkgLower.contains('กระป๋อง')) {
                binColor = Colors.yellow;
                binIcon = Icons.recycling;
                instruction = "ทิ้งถังเหลือง (รีไซเคิล)";
              } else if (pkgLower.contains('paper') ||
                  pkgLower.contains('carton') ||
                  pkgLower.contains('กล่อง') ||
                  pkgLower.contains('กระดาษ')) {
                binColor = Colors.yellow;
                binIcon = Icons.recycling;
                instruction = "ทิ้งถังเหลือง (รีไซเคิล)";
              } else if (pkgLower.contains('bottle')) {
                // Generic "bottle" ไม่ชัดว่า glass หรือ plastic
                // ดูจากชื่อสินค้า
                String productLower = productName.toLowerCase();
                if (productLower.contains('sauce') ||
                    productLower.contains('jam') ||
                    productLower.contains('honey') ||
                    productLower.contains('paste') ||
                    productLower.contains('น้ำจิ้ม') ||
                    productLower.contains('แยม') ||
                    productLower.contains('น้ำผึ้ง')) {
                  // คาดว่า glass ขวด
                  binColor = Colors.yellow;
                  binIcon = Icons.recycling;
                  instruction = "ทิ้งถังเหลือง (รีไซเคิล - ขวดแก้ว)";
                } else {
                  // Default: ขวด recyclable
                  binColor = Colors.yellow;
                  binIcon = Icons.recycling;
                  instruction = "ทิ้งถังเหลือง (รีไซเคิล)";
                }
              }
            }

            // cache result
            _barcodeCache[code] = {
              'title': productName,
              'detail': "$instruction\nวัสดุ: $packaging\nรหัส: $code",
              'score': '100%',
              'color': binColor,
              'icon': binIcon,
            };

            // แสดงผลลัพธ์
            _setResult(
              productName,
              "$instruction\nวัสดุ: $packaging\nรหัส: $code",
              "100%",
              binColor,
              binIcon,
            );
          } else {
            _setResult(
              "ไม่พบข้อมูลสินค้า",
              "รหัส: $code\nไม่มีข้อมูลในฐานข้อมูล OpenFoodFacts",
              "100%",
              Colors.grey,
              Icons.help_outline,
            );
          }
        } else {
          _setResult(
            "เชื่อมต่อล้มเหลว",
            "เกิดข้อผิดพลาดจากเซิร์ฟเวอร์ API",
            "0%",
            Colors.red,
            Icons.error,
          );
        }
      } catch (e) {
        _setResult(
          "ข้อผิดพลาด",
          "ไม่สามารถดึงข้อมูลได้: $e",
          "0%",
          Colors.red,
          Icons.warning,
        );
      }
    }
  }

  // ---------------- 2. GALLERY & AI LOGIC (แบบแยกราง) ----------------
  Future<void> _processImage(ImageSource source) async {
    if (isLoading) return;
    setState(() => isScanning = false); // ปิดการสแกนกล้องสดชั่วคราว

    // 1. เลือกรูปจากแกลลอรี่ (หรือถ่ายจากกล้องโหมด AI)
    final photo = await ImagePicker().pickImage(source: source, maxWidth: 800);
    if (photo == null) {
      _reset();
      return;
    }

    // แสดงรูปที่เลือกบนจอ เปิดโหลดดิ่ง และตั้ง isScanning เป็น true ชั่วคราวเพื่อให้ฟังก์ชันตรวจจับทำงานได้
    setState(() {
      _imageFile = photo;
      isLoading = true;
      rTitle = "";
      isScanning = true;
    });

    try {
      if (currentMode == ScanMode.barcode) {
        // ----------------------------------------------------
        // 🔀 รางที่ 1: โหมดบาร์โค้ด (สั่งให้แกะบาร์โค้ดจากรูปภาพ)
        // ----------------------------------------------------
        final capture = await cameraController.analyzeImage(photo.path);

        if (capture is BarcodeCapture && capture.barcodes.isNotEmpty) {
          await onBarcodeDetect(capture);
        } else {
          await Future.delayed(const Duration(seconds: 1));
          if (rTitle.isEmpty)
            _setResult(
              "ไม่พบบาร์โค้ด",
              "ระบบไม่พบบาร์โค้ดในรูปภาพนี้ หรือบาร์โค้ดไม่ชัดเจน\nกรุณาลองถ่ายใหม่โดยวางบาร์โค้ดให้อยู่ในกรอบหรือใช้โหมด AI แทน",
              "0%",
              Colors.grey,
              Icons.qr_code_scanner,
            );
        }
      } else {
        // ----------------------------------------------------
        // 🔀 รางที่ 2: โหมด AI Object (ส่งขึ้น Google Cloud Vision)
        // ----------------------------------------------------
        // encode on background isolate to avoid blocking UI
        String base64Image = await compute(
          _encodeImageToBase64Sync,
          photo.path,
        );
        final apiKey = dotenv.env['GOOGLE_VISION_API_KEY'] ?? '';
        final proxyUrl = dotenv.env['VISION_PROXY_URL'] ?? '';
        Uri uri;
        Map<String, dynamic> body;
        if (proxyUrl.isNotEmpty) {
          uri = Uri.parse(proxyUrl);
          body = {"image": base64Image};
        } else {
          uri = Uri.parse(
            "https://vision.googleapis.com/v1/images:annotate?key=$apiKey",
          );
          body = {
            "requests": [
              {
                "image": {"content": base64Image},
                "features": [
                  {"type": "OBJECT_LOCALIZATION"},
                  {"type": "LABEL_DETECTION"},
                  {"type": "LOGO_DETECTION"},
                ],
              },
            ],
          };
        }

        // Build headers: always set content-type; if calling a proxy (e.g., Supabase Edge Function)
        // include optional auth headers: VISION_PROXY_KEY or SUPABASE_ACCESS_TOKEN from .env
        final Map<String, String> headers = {
          "Content-Type": "application/json",
        };
        final proxyKey = dotenv.env['VISION_PROXY_KEY'] ?? '';
        final supabaseToken = dotenv.env['SUPABASE_ACCESS_TOKEN'] ?? '';
        if (proxyUrl.isNotEmpty && proxyKey.isNotEmpty)
          headers['x-proxy-key'] = proxyKey;
        if (proxyUrl.isNotEmpty && supabaseToken.isNotEmpty)
          headers['Authorization'] = 'Bearer $supabaseToken';

        var res = await http
            .post(uri, headers: headers, body: jsonEncode(body))
            .timeout(const Duration(seconds: 15));

        if (res.statusCode == 200) {
          _analyzeAIMultiple(jsonDecode(res.body));
        } else {
          throw Exception("Server Error: ${res.statusCode}");
        }
      }
    } catch (e) {
      _setResult("Error", "เกิดข้อผิดพลาด: $e", "0%", Colors.red, Icons.error);
    } finally {
      if (mounted && isLoading && rTitle.isEmpty)
        setState(() => isLoading = false);
    }
  }

  // helper used with compute() must be a top-level or static function
  static String _encodeImageToBase64Sync(String path) {
    return base64Encode(File(path).readAsBytesSync());
  }

  // ฟังก์ชันหลัก: ประมวลผล labelAnnotations หลายรายการ
  void _analyzeAIMultiple(Map<String, dynamic> json) {
    var res = json['responses']?[0] ?? {};
    if (res.isEmpty) {
      return _setResult(
        "No Object",
        "วิเคราะห์ไม่ได้",
        "0%",
        Colors.grey,
        Icons.close,
      );
    }

    String text = (res['textAnnotations']?[0]['description'] ?? "")
        .toString()
        .toLowerCase();
    String logo = "";
    if (res['logoAnnotations'] != null && res['logoAnnotations'].isNotEmpty) {
      logo = res['logoAnnotations'][0]['description'].toString().toLowerCase();
    }

    List<dynamic> labels = res['labelAnnotations'] ?? [];
    if (labels.isEmpty) {
      return _setResult(
        "No Object",
        "วิเคราะห์ไม่ได้",
        "0%",
        Colors.grey,
        Icons.close,
      );
    }

    // สร้างรายการผลลัพธ์ที่มากขึ้น โดยเรียงตามความแม่นยำและหลีกเลี่ยงรายการที่ซ้ำกัน
    final Set<String> usedBinTypes =
        {}; // เก็บประเภทถังเพื่อหลีกเลี่ยงการซ้ำกัน
    aiResults = [];

    for (var labelItem in labels) {
      if (aiResults.length >= 5) break; // Max 5 results

      String label = labelItem['description'] ?? "Unknown";
      double score = (labelItem['score'] ?? 0) * 100;
      String labelLower = label.toLowerCase();
      String textAndLogo = "$text | $logo";

      // ตรวจจับสี/ไม่ใช่ขยะ หรือสิ่งที่เกี่ยวกับมนุษย์/ใบหน้า/การแสดงอารมณ์ เช่น smile แล้วข้ามไป
      if (_isJustColor(labelLower) || _isHumanRelated(labelLower)) {
        continue;
      }

      var result = _classifyWaste(label, score, textAndLogo);

      // หลีกเลี่ยงการซ้ำขยะประเภทเดียวกัน
      String binKey = "${result['title']}_${result['binColor']}";
      if (!usedBinTypes.contains(binKey)) {
        usedBinTypes.add(binKey);
        aiResults.add(result);
      }
    }

    if (aiResults.isNotEmpty) {
      currentResultIndex = 0;
      _displayAIResult(0);
    } else {
      _setResult(
        "No Object",
        "ไม่สามารถระบุประเภทขยะได้",
        "0%",
        Colors.grey,
        Icons.close,
      );
    }
  }

  // ฟังก์ชันแยกประเภทขยะจากชื่อและเลขที่
  Map<String, dynamic> _classifyWaste(
    String label,
    double score,
    String textAndLogo,
  ) {
    String labelLower = label.toLowerCase();
    String scoreText = "${score.toStringAsFixed(2)}%";

    // ========== TEXT/LOGO RECOGNITION (ตรวจจากชื่อแบรนด์) ==========

    // 1. เบียร์และเครื่องดื่มแอลกอฮอล์
    if (textAndLogo.contains(
      RegExp(
        r'singha|chang|leo|heineken|beer|alcohol|bier|lager|whiskey|rum|vodka|gin',
      ),
    )) {
      return {
        'title': 'Beer/Alcohol Can',
        'detail': 'ทิ้งถังเหลือง (รีไซเคิล)',
        'score': scoreText,
        'binColor': Colors.yellow,
        'icon': Icons.recycling,
      };
    }

    // 2. นม/ไข่กว้าง
    if (textAndLogo.contains(
      RegExp(
        r'milk|dairy|yogurt|plain|meiji|lactasoy|anchor|ตราแรด|ปัญญา|ดาริ',
      ),
    )) {
      return {
        'title': 'Dairy/Milk Product',
        'detail': 'ทิ้งถังเหลือง (รีไซเคิล)',
        'score': scoreText,
        'binColor': Colors.yellow,
        'icon': Icons.local_drink,
      };
    }

    // 3. น้ำดื่ม/น้ำแร่
    if (textAndLogo.contains(
      RegExp(r'namthip|minere|aura|crystal|purra|water|น้ำดื่ม|น้ำแร่|aqua'),
    )) {
      return {
        'title': 'Water/Mineral Bottle',
        'detail': 'ทิ้งถังเหลือง (รีไซเคิล)',
        'score': scoreText,
        'binColor': Colors.yellow,
        'icon': Icons.water_drop,
      };
    }

    // 4. เครื่องดื่มหวาน (Soft Drink)
    if (textAndLogo.contains(
      RegExp(
        r'coca-cola|coke|cola|pepsi|est|fanta|sprite|soda|soft drink|น้ำอัดลม|7up',
      ),
    )) {
      return {
        'title': 'Soft Drink Can/Bottle',
        'detail': 'ทิ้งถังเหลือง (รีไซเคิล)',
        'score': scoreText,
        'binColor': Colors.yellow,
        'icon': Icons.local_drink,
      };
    }

    // 5. น้ำผลไม้/น้ำหวาน
    if (textAndLogo.contains(
      RegExp(
        r'juice|fruit drink|tang|ดิบ|น้ำสักวน|น้ำอ้วยอ่อย|น้ำส้ม|orange|apple|grape',
      ),
    )) {
      return {
        'title': 'Juice/Fruit Drink Bottle',
        'detail': 'ทิ้งถังเหลือง (รีไซเคิล)',
        'score': scoreText,
        'binColor': Colors.yellow,
        'icon': Icons.local_drink,
      };
    }

    // 6. กาแฟ/ชา
    if (textAndLogo.contains(
      RegExp(r'coffee|tea|nescafe|ovaltine|แฟรี่|ชา|กาแฟ|latte|cappuccino'),
    )) {
      return {
        'title': 'Coffee/Tea Bottle',
        'detail': 'ทิ้งถังเหลือง (รีไซเคิล)',
        'score': scoreText,
        'binColor': Colors.yellow,
        'icon': Icons.local_drink,
      };
    }

    // 7. ยา/วิตามิน
    if (textAndLogo.contains(
      RegExp(r'medicine|drug|vitamin|pill|tablet|คลินิค|ยา|วิตามิน|เวชสาส'),
    )) {
      return {
        'title': 'Medicine/Pharmacy',
        'detail': 'ทิ้งถังแดง (ขยะอันตราย - ยา)',
        'score': scoreText,
        'binColor': Colors.red,
        'icon': Icons.dangerous,
      };
    }

    // 8. น้ำยาทำความสะอาด/ผลิตภัณฑ์ทำความสะอาด
    if (textAndLogo.contains(
      RegExp(
        r'cleaner|soap|detergent|disinfect|bleach|lion|vim|cif|น้ำยา|สบู่|ผงซักฟอก',
      ),
    )) {
      return {
        'title': 'Cleaning Product',
        'detail': 'ทิ้งถังแดง (ขยะอันตราย - สารเคมี)',
        'score': scoreText,
        'binColor': Colors.red,
        'icon': Icons.dangerous,
      };
    }

    // 9. กระดาษ/กล่อง
    if (textAndLogo.contains(
      RegExp(r'box|paper|carton|cardboard|กล่อง|กระดาษ'),
    )) {
      return {
        'title': 'Paper/Cardboard Box',
        'detail': 'ทิ้งถังเหลือง (รีไซเคิล)',
        'score': scoreText,
        'binColor': Colors.yellow,
        'icon': Icons.recycling,
      };
    }

    // 10. ขนม/อาหารแห้ง
    if (textAndLogo.contains(
      RegExp(r'lay|tasto|snack|chip|crisp|doritos|ขนม|ชิป'),
    )) {
      return {
        'title': 'Snack Bag',
        'detail': 'ทิ้งถังน้ำเงิน (ขยะทั่วไป)',
        'score': scoreText,
        'binColor': Colors.blue,
        'icon': Icons.fastfood,
      };
    }

    if (textAndLogo.contains(RegExp(r'tissue|napkin|wipe|ทิชชู่|กระดาษชำระ'))) {
      return {
        'title': 'Tissue/Paper Wipe',
        'detail': 'ทิ้งถังน้ำเงิน (ขยะทั่วไป)',
        'score': scoreText,
        'binColor': Colors.blue,
        'icon': Icons.delete,
      };
    }

    // ========== LABEL DETECTION (ตรวจจากคำอธิบาย AI) ==========

    // Dairy (นม/โยเกิร์ต)
    if (labelLower.contains(
      RegExp(r'milk|dairy|yogurt|cream|cheese|butter|condensed milk'),
    )) {
      return {
        'title': label,
        'detail': 'ทิ้งถังเหลือง (รีไซเคิล)',
        'score': scoreText,
        'binColor': Colors.yellow,
        'icon': Icons.local_drink,
      };
    }

    // Beverage & Drink
    if (labelLower.contains(
      RegExp(
        r'soft drink|beverage|beer|alcohol|soda|cola|drink|juice|water|coffee|tea',
      ),
    )) {
      return {
        'title': label,
        'detail': 'ทิ้งถังเหลือง (รีไซเคิล)',
        'score': scoreText,
        'binColor': Colors.yellow,
        'icon': Icons.local_drink,
      };
    }

    // Medicine & Medicine (ยา/วิตามิน)
    if (labelLower.contains(
      RegExp(r'medicine|drug|vitamin|pill|tablet|pharmaceutical|capsule'),
    )) {
      return {
        'title': label,
        'detail': 'ทิ้งถังแดง (ขยะอันตราย - ยา)',
        'score': scoreText,
        'binColor': Colors.red,
        'icon': Icons.dangerous,
      };
    }

    // Hazardous Liquid (น้ำมัน/สารเคมี) - เฉพาะลิควิดอันตรายที่ชัด ไม่เอา "liquid" คำเดียว
    if (labelLower.contains(
      RegExp(
        r'oil|chemical|liquid cleaner|liquid soap|liquid medicine|liquid paint|paint|solvent|thinner|น้ำมัน|สารเคมี|toxic|hazard',
      ),
    )) {
      return {
        'title': label,
        'detail': 'ทิ้งถังแดง (ขยะอันตราย - สารเคมี)',
        'score': scoreText,
        'binColor': Colors.red,
        'icon': Icons.dangerous,
      };
    }

    // Generic "Liquid" - ไม่ชัดว่าอันตรายหรือไม่ แนะนำให้เช็คข้างบรรจุภัณฑ์
    if (labelLower.contains('liquid')) {
      return {
        'title': label,
        'detail':
            'ทิ้งถังน้ำเงิน (ขยะทั่วไป)\nเช็คข้างบรรจุภัณฑ์เพื่อให้แน่ใจว่าอันตรายหรือไม่',
        'score': scoreText,
        'binColor': Colors.blue,
        'icon': Icons.help_outline,
      };
    }

    // Cleaning Product
    if (labelLower.contains(
      RegExp(r'cleaner|detergent|soap|disinfect|bleach|sanitizer'),
    )) {
      return {
        'title': label,
        'detail': 'ทิ้งถังแดง (ขยะอันตราย)',
        'score': scoreText,
        'binColor': Colors.red,
        'icon': Icons.dangerous,
      };
    }

    // Food/Organic
    if (labelLower.contains(
      RegExp(r'food|fruit|vegetable|bread|bakery|pastry|meat|fish|seafood'),
    )) {
      return {
        'title': label,
        'detail': 'ทิ้งถังเขียว (ขยะเปียก)',
        'score': scoreText,
        'binColor': Colors.green,
        'icon': Icons.restaurant,
      };
    }

    // Bottle/Can/Glass/Metal/Plastic (รีไซเคิล)
    if (labelLower.contains(
      RegExp(r'bottle|plastic|glass|metal|can|tin|jar|container|cup'),
    )) {
      return {
        'title': label,
        'detail': 'ทิ้งถังเหลือง (รีไซเคิล)',
        'score': scoreText,
        'binColor': Colors.yellow,
        'icon': Icons.recycling,
      };
    }

    // Paper/Cardboard
    if (labelLower.contains(
      RegExp(r'paper|cardboard|box|carton|tissue|napkin'),
    )) {
      return {
        'title': label,
        'detail': 'ทิ้งถังเหลือง (รีไซเคิล)',
        'score': scoreText,
        'binColor': Colors.yellow,
        'icon': Icons.recycling,
      };
    }

    // Textile/Cloth (เสื้อผ้า)
    if (labelLower.contains(
      RegExp(r'cloth|fabric|textile|clothing|garment|shirt|pants|towel'),
    )) {
      return {
        'title': label,
        'detail': 'ทิ้งถังน้ำเงิน (ขยะทั่วไป)',
        'score': scoreText,
        'binColor': Colors.blue,
        'icon': Icons.checkroom,
      };
    }

    // Foam/Styrofoam
    if (labelLower.contains(
      RegExp(r'foam|styrofoam|polystyrene|cushion|padding'),
    )) {
      return {
        'title': label,
        'detail': 'ทิ้งถังน้ำเงิน (ขยะทั่วไป)',
        'score': scoreText,
        'binColor': Colors.blue,
        'icon': Icons.dashboard,
      };
    }

    if (_isHazardous(labelLower)) {
      return {
        'title': label,
        'detail': 'ทิ้งถังแดง (ขยะอันตราย)',
        'score': scoreText,
        'binColor': Colors.red,
        'icon': Icons.dangerous,
      };
    }

    // Default
    return {
      'title': label,
      'detail': 'ทิ้งถังน้ำเงิน (ขยะทั่วไป)\nหรือตรวจสอบข้างบรรจุภัณฑ์',
      'score': scoreText,
      'binColor': Colors.blue,
      'icon': Icons.help_outline,
    };
  }

  // ฟังก์ชันวิเคราะห์ Barcode Range (GS1) เพื่อแม่นยำกว่า
  // ดูจากตัวเลข 2-3 ตัวแรกของ barcode เพื่อทายวัสดุ
  String _classifyByBarcodeRange(String code) {
    if (code.length < 2) return '';

    String prefix = code.substring(0, 2);

    // ========== THAILAND & SE ASIA (80-89) ==========
    // 88, 89 = ไทย
    if (prefix == '88' || prefix == '89') {
      return 'ขวดพลาสติก PET / กระป๋องอลูมิเนียม / ซองฟอยล์';
    }

    // ========== EUROPE (40-43) ==========
    // 40-43 = เยอรมนี, ฝรั่งเศส, สเปน, อิตาลี
    if (prefix == '40' || prefix == '41' || prefix == '42' || prefix == '43') {
      return 'ขวดแก้ว / พลาสติก / กระดาษ / กล่องกระดาษ';
    }

    // ========== JAPAN & EAST ASIA (45, 49) ==========
    // 45 = ญี่ปุ่น, 49 = ญี่ปุ่น
    if (prefix == '45' || prefix == '49') {
      return 'กล่องกระดาษ / ขวด / ถ้วยพลาสติก';
    }

    // ========== USA & CANADA (00-09) ==========
    if (prefix == '00' ||
        prefix == '01' ||
        prefix == '02' ||
        prefix == '03' ||
        prefix == '04' ||
        prefix == '05' ||
        prefix == '06' ||
        prefix == '07' ||
        prefix == '08' ||
        prefix == '09') {
      return 'ขวด / กล่องกระดาษ / ถ้วยพลาสติก';
    }

    // ========== UK & IRELAND (50) ==========
    if (prefix == '50') {
      return 'ขวดแก้ว / กระดาษ / พลาสติก';
    }

    // ========== AUSTRALIA (93) ==========
    if (prefix == '93') {
      return 'ขวด / กล่องกระดาษ / ถ้วยพลาสติก';
    }

    // ========== VIETNAM (89) ==========
    if (prefix == '89') {
      return 'ขวดพลาสติก / กระป๋อง / ซองฟอยล์';
    }

    // ค่าเริ่มต้น
    return '';
  }

  // ฟังก์ชันช่วยเช็ค Hazardous keywords
  bool _isHazardous(String text) {
    final hazardousKeywords = [
      'battery',
      'spray',
      'insecticide',
      'chemical',
      'electronic',
      'phone',
      'mobile',
      'smartphone',
      'computer',
      'device',
      'electric',
      'laptop',
      'tablet',
      'circuit',
      'telephony',
      'communication',
      'hardware',
      'gadget',
      'accessory',
      'phone case',
      'charger',
      'usb',
      'cable',
      'adapter',
      'peripheral',
      'keyboard',
      'mouse',
      'monitor',
      'display',
      'printer',
      'scanner',
      'copier',
      'office equipment',
      'fax machine',
      'toner',
      'technology',
    ];
    return hazardousKeywords.any((keyword) => text.contains(keyword));
  }

  // ฟังก์ชันช่วยเช็คว่าเป็นแค่สี/ไม่ใช่ขยะ
  bool _isJustColor(String text) {
    final colorKeywords = [
      'silver',
      'gold',
      'black',
      'white',
      'red',
      'blue',
      'green',
      'yellow',
      'pink',
      'purple',
      'orange',
      'brown',
      'gray',
      'grey',
      'beige',
      'color',
      'hue',
      'shade',
      'tint',
      'tone',
    ];
    return colorKeywords.any((keyword) => text.contains(keyword));
  }

  // ฟังก์ชันช่วยเช็คว่าเกี่ยวข้องกับมนุษย์/ใบหน้า/การแสดงอารมณ์ (เช่น smile, face, person)
  bool _isHumanRelated(String text) {
    final humanKeywords = [
      'person',
      'people',
      'human',
      'man',
      'woman',
      'boy',
      'girl',
      'kid',
      'child',
      'face',
      'facial',
      'smile',
      'smiling',
      'laugh',
      'laughing',
      'mouth',
      'lip',
      'cheek',
      'eye',
      'eyelid',
      'pupil',
      'iris',
      'eyebrow',
      'nose',
      'ear',
      'hair',
      'head',
      'hand',
      'arm',
      'finger',
      'thumb',
      'palm',
      'wrist',
      'elbow',
      'leg',
      'thigh',
      'knee',
      'ankle',
      'foot',
      'toe',
      'body',
      'torso',
      'chest',
      'back',
      'shoulder',
      'neck',
      'skin',
      'gesture',
      'selfie',
      'portrait',
    ];
    return humanKeywords.any((keyword) => text.contains(keyword));
  }

  // แสดงผลลัพธ์ที่เลือก
  void _displayAIResult(int index) {
    if (index < 0 || index >= aiResults.length) return;
    final result = aiResults[index];
    setState(() {
      currentResultIndex = index;
      rTitle = result['title'] ?? '';
      rDetail = result['detail'] ?? '';
      rScore = result['score'] ?? '0%';
      rColor = result['binColor'] ?? Colors.white;
      rIcon = result['icon'] ?? Icons.info;
      isLoading = false;
    });
  }

  // แสดง Modal เพื่อเลือกผลลัพธ์เพิ่มเติม
  void _showMoreResultsModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext context) {
        return ListView.builder(
          itemCount: aiResults.length,
          itemBuilder: (context, index) {
            final result = aiResults[index];
            final isSelected = index == currentResultIndex;
            return Container(
              color: isSelected
                  ? Colors.tealAccent.withValues(alpha: 0.2)
                  : null,
              child: ListTile(
                leading: Icon(
                  result['icon'] ?? Icons.help_outline,
                  color: result['binColor'] ?? Colors.white,
                ),
                title: Text(
                  result['title'] ?? 'Unknown',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  result['detail'] ?? '',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Text(
                  result['score'] ?? '0%',
                  style: TextStyle(
                    color: result['binColor'] ?? Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onTap: () {
                  _displayAIResult(index);
                  Navigator.pop(context);
                },
              ),
            );
          },
        );
      },
    );
  }

  // วิเคราะห์ผล JSON เพื่อระบุประเภทขยะ (ของระบบ AI) - ใช้สำหรับ ML Kit
  // ---------------- 3. UI BUILDER ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: _imageFile != null
                ? Image.file(File(_imageFile!.path), fit: BoxFit.cover)
                : MobileScanner(
                    controller: cameraController,
                    onDetect: onBarcodeDetect,
                    fit: BoxFit.cover,
                  ),
          ),

          if (_imageFile == null && rTitle.isEmpty) _buildScannerOverlay(),

          Positioned(top: 50, left: 20, right: 20, child: _buildHeader()),

          if (isLoading)
            const Center(
              child: CircularProgressIndicator(color: Colors.tealAccent),
            ),

          if (rTitle.isNotEmpty) _buildResultCard(),

          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildBottomControls(),
          ),
        ],
      ),
    );
  }

  Widget _buildScannerOverlay() {
    final isBarcode = currentMode == ScanMode.barcode;
    final frameColor = isBarcode ? Colors.blue : Colors.green;
    final instructionText = isBarcode
        ? 'Point camera at barcode'
        : 'Align waste item in frame';

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Mode indicator chip (small & subtle)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: frameColor.withOpacity(0.2),
              border: Border.all(color: frameColor, width: 1),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Text(
              isBarcode ? 'Barcode Mode' : 'AI Mode',
              style: TextStyle(
                color: frameColor,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Smooth rounded scan frame (matches design)
          Container(
            width: 280,
            height: isBarcode ? 150 : 280,
            decoration: BoxDecoration(
              border: Border.all(color: frameColor, width: 2),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          const SizedBox(height: 15),
          // Instructional text
          Text(
            instructionText,
            style: TextStyle(
              color: frameColor,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      const Text(
        "WasteVision",
        style: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      IconButton(
        icon: Icon(
          isTorchOn ? Icons.flash_on : Icons.flash_off,
          color: Colors.white,
        ),
        onPressed: () {
          cameraController.toggleTorch();
          setState(() => isTorchOn = !isTorchOn);
        },
      ),
    ],
  );

  Widget _buildResultCard() {
    bool hasMoreResults = aiResults.length > 1;
    return Positioned(
      bottom: 180,
      left: 20,
      right: 20,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        // BackdropFilter (blur) temporarily removed for startup probe
        child: Container(
          padding: const EdgeInsets.all(20),
          color: Colors.black87,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(rIcon, color: rColor, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      rTitle,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: rColor,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => _reset(full: true),
                  ),
                ],
              ),
              const Divider(color: Colors.white12, height: 20),
              Text(
                rDetail,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 15),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    currentMode == ScanMode.barcode
                        ? "Confidence"
                        : "AI Confidence",
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  Text(
                    rScore,
                    style: TextStyle(
                      color: rColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: double.tryParse(rScore.replaceAll('%', ''))! / 100,
                  color: rColor,
                  backgroundColor: Colors.white10,
                  minHeight: 6,
                ),
              ),
              if (hasMoreResults) ...[
                const SizedBox(height: 15),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _showMoreResultsModal,
                    icon: const Icon(Icons.list),
                    label: Text(
                      'แสดงผลลัพธ์เพิ่มเติม (${aiResults.length - 1} รายการ)',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.tealAccent,
                      foregroundColor: Colors.black,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Container(
      height: 180,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black, Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(
                          Icons.photo_library,
                          color: Colors.white,
                          size: 30,
                        ),
                        onPressed: () => _processImage(ImageSource.gallery),
                      ),
                      const Text(
                        "Gallery",
                        style: TextStyle(color: Colors.white54, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: SizedBox(
                      width: 75,
                      height: 75,
                      child: (currentMode == ScanMode.ai && rTitle.isEmpty)
                          ? GestureDetector(
                              onTap: () => _processImage(ImageSource.camera),
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 4,
                                  ),
                                  color: Colors.white24,
                                ),
                                child: const Icon(
                                  Icons.camera,
                                  color: Colors.white,
                                  size: 30,
                                ),
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
                const Spacer(),
              ],
            ),
            Container(
              height: 50,
              margin: const EdgeInsets.only(bottom: 10, top: 10),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _modeBtn("Barcode", ScanMode.barcode),
                  _modeBtn("AI Object", ScanMode.ai),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeBtn(String txt, ScanMode m) {
    bool active = currentMode == m;
    return GestureDetector(
      onTap: () => _switchMode(m),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: active ? Colors.tealAccent : null,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          txt,
          style: TextStyle(
            color: active ? Colors.black : Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
