import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: WasteScannerScreen(),
    ),
  );
}

class WasteScannerScreen extends StatefulWidget {
  const WasteScannerScreen({super.key});

  @override
  State<WasteScannerScreen> createState() => _WasteScannerScreenState();
}

class _WasteScannerScreenState extends State<WasteScannerScreen> {
  // ==========================================
  // 🔑 ใส่ API Key ของคุณตรงนี้
  // ==========================================
  final String apiKey = "AIzaSyDoSa9rbXOTFjedIBNC-XFqsbAEDGzeVug";
  // ==========================================

  String resultText = "📷 พร้อมสแกน";
  String detailText = "ส่องบาร์โค้ด หรือ กดปุ่มด้านล่างเพื่อใช้ AI";
  Color statusColor = Colors.white;
  bool isScanning = true;
  bool isLoading = false;
  XFile? _imageFile;

  // 1️⃣ ฟังก์ชันสแกนบาร์โค้ด
  void onBarcodeDetect(BarcodeCapture capture) {
    if (!isScanning) return;
    final List<Barcode> barcodes = capture.barcodes;

    for (final barcode in barcodes) {
      if (barcode.rawValue != null) {
        setState(() {
          isScanning = false;
          _processBarcodeResult(barcode.rawValue!);
        });
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && _imageFile == null && !isLoading) {
            setState(() => isScanning = true);
          }
        });
        break;
      }
    }
  }

  void _processBarcodeResult(String code) {
    if (code.startsWith('885')) {
      _updateResult(
        "✅ สินค้าไทย ($code)",
        "📦 ขวดพลาสติก (PET)\n♻️ ทิ้งถังรีไซเคิล",
        Colors.green.shade100,
      );
    } else {
      _updateResult(
        "📦 รหัส: $code",
        "ไม่พบข้อมูลในฐานข้อมูล",
        Colors.orange.shade100,
      );
    }
  }

  // 2️⃣ ฟังก์ชันถ่ายรูป/เลือกรูป + ยิง API ☁️
  // รับค่า source เพื่อเลือกว่าจะเอารูปจาก กล้อง หรือ อัลบั้ม
  Future<void> _pickAndAnalyzeImage(ImageSource source) async {
    setState(() => isScanning = false); // หยุดสแกนบาร์โค้ดชั่วคราว

    final ImagePicker picker = ImagePicker();
    final XFile? photo = await picker.pickImage(
      source: source,
      maxWidth: 800,
      maxHeight: 800,
    );

    if (photo == null) {
      // ถ้ากดเลือกแล้วเปลี่ยนใจ ไม่เอา ให้กลับไปสแกนต่อ
      setState(() => isScanning = true);
      return;
    }

    setState(() {
      _imageFile = photo;
      isLoading = true; // เริ่มหมุนติ้วๆ
      resultText = "☁️ กำลังถาม Google...";
      detailText = "รอสักครู่ AI กำลังอ่านรูป...";
      statusColor = Colors.white;
    });

    try {
      List<int> imageBytes = await File(photo.path).readAsBytes();
      String base64Image = base64Encode(imageBytes);

      String url =
          "https://vision.googleapis.com/v1/images:annotate?key=$apiKey";
      Map<String, dynamic> requestBody = {
        "requests": [
          {
            "image": {"content": base64Image},
            "features": [
              {"type": "TEXT_DETECTION", "maxResults": 1},
              {"type": "LABEL_DETECTION", "maxResults": 10},
            ],
          },
        ],
      };

      var response = await http.post(
        Uri.parse(url),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 200) {
        var jsonResponse = jsonDecode(response.body);
        _analyzeApiResponse(jsonResponse);
      } else {
        _updateResult(
          "❌ Error",
          "Server: ${response.statusCode}",
          Colors.red.shade100,
        );
      }
    } catch (e) {
      _updateResult("❌ เชื่อมต่อไม่ได้", "Error: $e", Colors.red.shade100);
    } finally {
      setState(() => isLoading = false); // หยุดหมุน
    }
  }

  // 3️⃣ สมองแยกขยะ
  void _analyzeApiResponse(Map<String, dynamic> json) {
    if (json['responses'][0] == null || json['responses'][0].isEmpty) {
      _updateResult(
        "❓ ไม่รู้จัก",
        "AI มองไม่ออก ลองใหม่",
        Colors.grey.shade200,
      );
      return;
    }

    var responses = json['responses'][0];

    String fullText = "";
    if (responses['textAnnotations'] != null) {
      fullText = responses['textAnnotations'][0]['description']
          .toString()
          .toLowerCase();
    }

    List<String> labels = [];
    if (responses['labelAnnotations'] != null) {
      for (var label in responses['labelAnnotations']) {
        labels.add(label['description']);
      }
    }
    String foundLabels = labels.join(", ");

    String title = "";
    String detail = "";
    Color color = Colors.white;
    bool found = false;

    // Logic เดิม
    if (fullText.contains("สิงห์") || fullText.contains("singha")) {
      title = "🍺 พบยี่ห้อ: สิงห์";
      detail = "ขวดแก้ว/กระป๋อง -> ขายได้";
      color = Colors.yellow.shade100;
      found = true;
    } else if (fullText.contains("น้ำทิพย์") || fullText.contains("namthip")) {
      title = "💧 พบยี่ห้อ: น้ำทิพย์";
      detail = "ขวด PET บิดได้ -> รีไซเคิล";
      color = Colors.cyan.shade100;
      found = true;
    } else if (fullText.contains("coke") ||
        fullText.contains("pepsi") ||
        fullText.contains("est")) {
      title = "🥤 พบยี่ห้อ: น้ำอัดลม";
      detail = "กระป๋อง/ขวด PET -> รีไซเคิล";
      color = Colors.blue.shade100;
      found = true;
    } else if (fullText.contains("7-select")) {
      title = "🏪 สินค้า 7-Eleven";
      detail = "ดูสัญลักษณ์ที่บรรจุภัณฑ์";
      color = Colors.orange.shade100;
      found = true;
    }

    if (!found) {
      if (foundLabels.contains("Bottle")) {
        title = "🧴 ตรวจพบ: ขวด";
        detail = "พลาสติก หรือ แก้ว -> รีไซเคิล";
        color = Colors.cyan.shade100;
      } else if (foundLabels.contains("Can")) {
        title = "🥫 ตรวจพบ: กระป๋อง";
        detail = "โลหะ -> รีไซเคิล";
        color = Colors.blue.shade100;
      } else {
        title = "❓ AI ไม่แน่ใจ";
        detail = "AI เห็นเป็น: $foundLabels";
        color = Colors.grey.shade200;
      }
    }

    _updateResult(title, detail, color);
  }

  void _updateResult(String title, String detail, Color color) {
    setState(() {
      resultText = title;
      detailText = detail;
      statusColor = color;
    });
  }

  void _resetScanner() {
    setState(() {
      isScanning = true;
      _imageFile = null;
      resultText = "📷 พร้อมสแกน";
      detailText = "ส่องบาร์โค้ด หรือ กดปุ่มด้านล่างเพื่อใช้ AI";
      statusColor = Colors.white;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Cloud Waste Scanner")),
      body: Column(
        children: [
          Expanded(
            flex: 6,
            child: Container(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_imageFile != null)
                    Image.file(File(_imageFile!.path), fit: BoxFit.contain)
                  else
                    MobileScanner(onDetect: onBarcodeDetect),

                  if (isLoading)
                    Container(
                      color: Colors.black54,
                      child: const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                    ),

                  if (_imageFile == null)
                    Center(
                      child: Container(
                        width: 250,
                        height: 250,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.redAccent, width: 3),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              color: statusColor,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    resultText,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    detailText,
                    style: TextStyle(fontSize: 16, color: Colors.grey[800]),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),

                  // 👇 โซนปุ่มกด (มี 2 ปุ่มแน่นอน!) 👇
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // ปุ่ม 1: ถ่ายรูป
                      ElevatedButton.icon(
                        onPressed: isLoading
                            ? null
                            : () => _pickAndAnalyzeImage(ImageSource.camera),
                        icon: const Icon(Icons.camera_alt),
                        label: const Text("ถ่ายรูป"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                        ),
                      ),

                      const SizedBox(width: 15),

                      // ปุ่ม 2: เลือกรูป
                      ElevatedButton.icon(
                        onPressed: isLoading
                            ? null
                            : () => _pickAndAnalyzeImage(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library),
                        label: const Text("เลือกรูป"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.purple,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 15),

                  // ปุ่มรีเซ็ต (แสดงเมื่อมีผลลัพธ์ค้างอยู่)
                  if (!isScanning && !isLoading)
                    TextButton.icon(
                      onPressed: _resetScanner,
                      icon: const Icon(Icons.refresh),
                      label: const Text("สแกนใหม่"),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.grey[800],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
