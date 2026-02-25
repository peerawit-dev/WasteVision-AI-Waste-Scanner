import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart'; // for compute
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';

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
  // Toggle to use on-device ML (ML Kit) instead of Google Cloud Vision
  final bool useOnDeviceMl = false;

  // ---------------- STATE ----------------
  ScanMode currentMode = ScanMode.barcode;
  String rTitle = "", rDetail = "", rScore = ""; // ตัวแปรเก็บผลลัพธ์
  Color rColor = Colors.white; // สีของธีมผลลัพธ์
  IconData rIcon = Icons.info;
  bool isScanning = true, isLoading = false, isTorchOn = false;
  XFile? _imageFile;
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
            if (packaging.isEmpty || packaging == 'null') {
              String nameLower = productName.toLowerCase();
              if (nameLower.contains('coca cola') ||
                  nameLower.contains('coke') ||
                  nameLower.contains('pepsi') ||
                  nameLower.contains('sprite') ||
                  nameLower.contains('est')) {
                packaging = 'คาดเดาจากชื่อ: ขวดพลาสติก/กระป๋อง';
                binColor = Colors.yellow;
                binIcon = Icons.recycling;
                instruction = "ทิ้งถังเหลือง (รีไซเคิล)";
              } else if (nameLower.contains('water') ||
                  nameLower.contains('น้ำดื่ม') ||
                  nameLower.contains('namthip') ||
                  nameLower.contains('crystal')) {
                packaging = 'คาดเดาจากชื่อ: ขวดพลาสติก PET';
                binColor = Colors.yellow;
                binIcon = Icons.recycling;
                instruction = "ทิ้งถังเหลือง (รีไซเคิล)";
              } else if (nameLower.contains('lay') ||
                  nameLower.contains('snack') ||
                  nameLower.contains('ขนม')) {
                packaging = 'คาดเดาจากชื่อ: ซองฟอยล์/พลาสติก';
                binColor = Colors.blue;
                binIcon = Icons.fastfood;
                instruction = "ทิ้งถังน้ำเงิน (ขยะทั่วไป)";
              } else {
                packaging = 'ไม่มีข้อมูลวัสดุในระบบ API';
                instruction =
                    "ทิ้งถังน้ำเงิน (ขยะทั่วไป) หรือเช็คข้างบรรจุภัณฑ์";
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
        // If configured to use on-device ML, use ML Kit labels to avoid sending images to cloud
        if (useOnDeviceMl) {
          final inputImage = InputImage.fromFilePath(photo.path);
          final labeler = ImageLabeler(
            options: ImageLabelerOptions(confidenceThreshold: 0.45),
          );
          final labels = await labeler.processImage(inputImage);
          await labeler.close();
          if (labels.isNotEmpty) {
            final top = labels.first;
            final labelText = top.label.toLowerCase();
            final scoreText = "${(top.confidence * 100).toInt()}%";
            // Simple mapping similar to cloud-based logic
            if (labelText.contains('bottle') ||
                labelText.contains('plastic') ||
                labelText.contains('jar')) {
              _setResult(
                "PET Bottle",
                "ทิ้งถังเหลือง (รีไซเคิล)",
                scoreText,
                Colors.yellow,
                Icons.water_drop,
              );
            } else if (labelText.contains('can') ||
                labelText.contains('aluminum') ||
                labelText.contains('beer')) {
              _setResult(
                "Beverage Can",
                "ทิ้งถังเหลือง (รีไซเคิล)",
                scoreText,
                Colors.yellow,
                Icons.local_drink,
              );
            } else if (labelText.contains('food') ||
                labelText.contains('fruit') ||
                labelText.contains('vegetable')) {
              _setResult(
                "Organic",
                "ทิ้งถังเขียว (ขยะเปียก)",
                scoreText,
                Colors.green,
                Icons.restaurant,
              );
            } else {
              _setResult(
                labelText,
                "ทิ้งถังน้ำเงิน (ขยะทั่วไป)",
                scoreText,
                Colors.blue,
                Icons.help_outline,
              );
            }
          } else {
            _setResult(
              "No Object",
              "ระบบไม่พบวัตถุในภาพ",
              "0%",
              Colors.grey,
              Icons.close,
            );
          }
        } else {
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
            _analyzeAI(jsonDecode(res.body));
          } else {
            throw Exception("Server Error: ${res.statusCode}");
          }
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

  // วิเคราะห์ผล JSON เพื่อระบุประเภทขยะ (ของระบบ AI)
  void _analyzeAI(Map<String, dynamic> json) {
    var res = json['responses']?[0] ?? {};
    if (res.isEmpty)
      return _setResult(
        "No Object",
        "วิเคราะห์ไม่ได้",
        "0%",
        Colors.grey,
        Icons.close,
      );

    String text = (res['textAnnotations']?[0]['description'] ?? "")
        .toString()
        .toLowerCase();
    String label = res['labelAnnotations']?[0]['description'] ?? "Unknown";
    double score = (res['labelAnnotations']?[0]['score'] ?? 0) * 100;

    // 🌟 ดึงข้อมูลโลโก้มาช่วยประมวลผล
    String logo = "";
    if (res['logoAnnotations'] != null && res['logoAnnotations'].isNotEmpty) {
      logo = res['logoAnnotations'][0]['description'].toString().toLowerCase();
    }
    String textAndLogo = "$text | $logo";

    // --- LOGIC แยกถังขยะ (ตรวจสอบ Object + Label + Logo) ---
    
    // 🛑 ดักจับอวัยวะมนุษย์ก่อนเลย!
    if (label.contains(RegExp(r'Finger|Hand|Arm|Person|Human|Skin|Nail'))) {
      return _setResult(
        "Human Body",
        "นี่มือคนครับ ไม่ใช่ขยะ! \nกรุณาวางขยะลงพื้นแล้วถ่ายใหม่",
        "${score.toInt()}%",
        Colors.orange,
        Icons.warning_amber_rounded,
      );
    }

    if (textAndLogo.contains(RegExp(r'singha|chang|leo|heineken|beer'))) {
      _setResult(
        "Glass/Can",
        "ทิ้งถังเหลือง (รีไซเคิล)",
        "100%",
        Colors.yellow,
        Icons.recycling,
      );
    } else if (textAndLogo.contains(
      RegExp(r'namthip|minere|aura|crystal|purra|water'),
    )) {
      _setResult(
        "PET Bottle",
        "ทิ้งถังเหลือง (รีไซเคิล)",
        "100%",
        Colors.yellow,
        Icons.water_drop,
      );
    } else if (textAndLogo.contains(
      RegExp(r'coca-cola|coke|cola|pepsi|est|fanta|sprite'),
    )) {
      _setResult(
        "Beverage Can",
        "ทิ้งถังเหลือง (รีไซเคิล)",
        "100%",
        Colors.yellow,
        Icons.local_drink,
      );
    } else if (textAndLogo.contains(
      RegExp(r'lay|tasto|snack|chip|crisp|doritos'),
    )) {
      _setResult(
        "Snack Bag",
        "ทิ้งถังน้ำเงิน (ขยะทั่วไป)",
        "90%",
        Colors.blue,
        Icons.fastfood,
      );
    } else if (textAndLogo.contains(RegExp(r'tissue|napkin|wipe'))) {
      _setResult(
        "Tissue",
        "ทิ้งถังน้ำเงิน (ขยะทั่วไป)",
        "95%",
        Colors.blue,
        Icons.delete,
      );
    }
    // ตรวจสอบจากรูปร่าง (Label)
    else if (label.contains(RegExp(r'Bottle|Plastic|Glass|Metal|Can|Tin'))) {
      _setResult(
        label,
        "ทิ้งถังเหลือง (รีไซเคิล)",
        "${score.toInt()}%",
        Colors.yellow,
        Icons.recycling,
      );
    } else if (label.contains(RegExp(r'Food|Fruit|Vegetable|Bread'))) {
      _setResult(
        label,
        "ทิ้งถังเขียว (ขยะเปียก)",
        "${score.toInt()}%",
        Colors.green,
        Icons.restaurant,
      );
    } else if (label.contains(RegExp(r'Battery|Spray|Insecticide|Chemical'))) {
      _setResult(
        "Hazardous",
        "ทิ้งถังแดง (ขยะอันตราย)",
        "${score.toInt()}%",
        Colors.red,
        Icons.dangerous,
      );
    } else {
      _setResult(
        label,
        "ทิ้งถังน้ำเงิน (ขยะทั่วไป)\nหรือตรวจสอบข้างบรรจุภัณฑ์",
        "${score.toInt()}%",
        Colors.blue,
        Icons.help_outline,
      );
    }
  }

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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 280,
            height: currentMode == ScanMode.barcode ? 150 : 280,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white54),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Stack(
              children: [
                for (var i = 0; i < 4; i++)
                  Positioned(
                    top: i < 2 ? 0 : null,
                    bottom: i >= 2 ? 0 : null,
                    left: i % 2 == 0 ? 0 : null,
                    right: i % 2 != 0 ? 0 : null,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        border: Border(
                          top: i < 2
                              ? const BorderSide(
                                  color: Colors.tealAccent,
                                  width: 4,
                                )
                              : BorderSide.none,
                          bottom: i >= 2
                              ? const BorderSide(
                                  color: Colors.tealAccent,
                                  width: 4,
                                )
                              : BorderSide.none,
                          left: i % 2 == 0
                              ? const BorderSide(
                                  color: Colors.tealAccent,
                                  width: 4,
                                )
                              : BorderSide.none,
                          right: i % 2 != 0
                              ? const BorderSide(
                                  color: Colors.tealAccent,
                                  width: 4,
                                )
                              : BorderSide.none,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Chip(
            label: Text(
              currentMode == ScanMode.barcode
                  ? "Now Is Barcode Scan Mode"
                  : "Now Is AI Object Scan Mode",
            ),
            backgroundColor: Colors.black54,
            labelStyle: const TextStyle(color: Colors.white),
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
