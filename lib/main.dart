import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Bug fix #8

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

enum ScanMode { barcode, ai }

class WasteScannerScreen extends StatefulWidget {
  const WasteScannerScreen({super.key});
  @override
  State<WasteScannerScreen> createState() => _WasteScannerScreenState();
}

class _WasteScannerScreenState extends State<WasteScannerScreen> {
  final String googleSheetUrl = dotenv.env['GOOGLE_SHEET_URL'] ?? '';
  final String apiKey = dotenv.env['GOOGLE_VISION_API_KEY'] ?? '';
  final MobileScannerController cameraController = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    returnImage: false,
  );

  ScanMode currentMode = ScanMode.barcode;
  bool isScanning = true, isLoading = false, isTorchOn = false;
  XFile? _imageFile;

  // Bug fix #1 #5 #6: แทน rTitle/rDetail ด้วย _rawResult
  // ทุก getter render ณ เวลาแสดงผล → reactive กับการสลับภาษาอัตโนมัติ
  Map<String, dynamic>? _rawResult;
  Color _rColor = Colors.white;
  IconData _rIcon = Icons.info;
  String _rScore = '';

  // Bug fix #1: cache เก็บ raw data ไม่ใช่ translated string
  final Map<String, Map<String, dynamic>> _barcodeCache = {};

  // Bug fix #3: aiResults เก็บ binKey แทน translated detail
  List<Map<String, dynamic>> aiResults = [];

  String? _tempScannedCode;
  int _consecutiveReads = 0;
  String? pendingBarcode;
  String? _notFoundCode;

  DateTime? _lastBarcodeRequestAt;
  static const Duration _barcodeCooldown = Duration(seconds: 2);
  static const Duration _offApiTimeout = Duration(seconds: 8);
  static const Duration _sheetApiTimeout = Duration(seconds: 12);
  static const Duration _visionApiTimeout = Duration(seconds: 15);

  // ---- Language toggle ----
  bool _isEnglish = false;

  @override
  void initState() {
    super.initState();
    _loadLanguagePref(); // Bug fix #8
  }

  // Bug fix #8: โหลดภาษาที่บันทึกไว้
  Future<void> _loadLanguagePref() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _isEnglish = prefs.getBool('isEnglish') ?? false);
  }

  // Bug fix #8: บันทึกภาษาพร้อมกับสลับ
  Future<void> _toggleLanguage() async {
    final newVal = !_isEnglish;
    setState(() => _isEnglish = newVal);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isEnglish', newVal);
  }

  String _t(String key) =>
      _isEnglish ? (_stringsEn[key] ?? key) : (_stringsTh[key] ?? key);

  // ---- Bug fix #5: computed getters → rebuild ทุกครั้งที่ setState (รวมตอนสลับภาษา) ----
  bool get _hasResult => _rawResult != null;

  String get _displayTitle {
    final raw = _rawResult;
    if (raw == null) return '';
    switch (raw['source']) {
      case 'not_found':
        return _t('not_found_title');
      case 'no_barcode':
        return _t('no_barcode');
      case 'no_object':
        return _t('no_object');
      case 'timeout':
        return _t('err_slow_network');
      case 'error':
        return _t('err_generic');
      default:
        return (raw['name'] as String?) ?? '';
    }
  }

  String get _displayDetail {
    final raw = _rawResult;
    if (raw == null) return '';
    switch (raw['source']) {
      // Bug fix #1 #6: OFF / cache → render ณ เวลาแสดงผล ไม่ใช่ตอน fetch
      case 'off':
      case 'cache':
        final inst = _t(raw['binKey'] as String);
        final pkg = (raw['packaging'] as String?)?.isNotEmpty == true
            ? raw['packaging'] as String
            : '-';
        return '$inst\n${_t('material')}: $pkg\n${_t('code')}: ${raw['code']}';
      // Bug fix #2: sheet → label ใช้ _t() แต่ instruction มาจาก sheet ตามเดิม
      case 'sheet':
        return '${raw['instruction']}\n${_t('material')}: ${raw['packaging']}\n${_t('code')}: ${raw['code']}';
      // Bug fix #3: AI → binKey render ณ เวลาแสดงผล
      case 'ai':
        return _t(raw['binKey'] as String);
      case 'user':
        return '${_t(raw['binKey'] as String)}\n${_t('dialog_thank')}';
      case 'not_found':
        return '${_t('code')}: ${raw['code']}\n${_t('origin')}: ${raw['country']}\n\n${_t('select_action')}';
      case 'no_barcode':
        return _t('no_barcode_detail');
      case 'no_object':
        return _t('no_object_detail');
      case 'timeout':
        return _t('err_slow_detail');
      case 'error':
        return '${_t('err_retry')}\n(${raw['errMsg'] ?? ''})';
      default:
        return '';
    }
  }
  // -----------------------------------------------------------------------

  static const Map<String, String> _stringsTh = {
    'mode_barcode': 'บาร์โค้ด',
    'mode_ai': 'AI วิเคราะห์',
    'overlay_barcode_mode': 'โหมดบาร์โค้ด',
    'overlay_ai_mode': 'โหมด AI',
    'overlay_barcode_hint': 'จ่อกล้องไปที่บาร์โค้ด',
    'overlay_ai_hint': 'จัดวางวัสดุให้อยู่ในกรอบ',
    'gallery': 'คลังภาพ',
    'confidence': 'ความแม่นยำ',
    'confidence_ai': 'ความแม่นยำ AI',
    'more_results': 'แสดงผลลัพธ์เพิ่มเติม',
    'not_found_title': 'ไม่พบข้อมูลรายการนี้',
    'not_found_action': 'คุณต้องการทำอะไร?',
    'btn_add_manual': 'เพิ่มข้อมูลเอง',
    'btn_ai_help': 'ให้ AI ช่วยดู',
    'err_slow_network': 'เครือข่ายช้า',
    'err_slow_detail':
        'ไม่ได้รับการตอบกลับจากเซิร์ฟเวอร์\nกรุณาลองใหม่อีกครั้ง',
    'err_generic': 'เกิดข้อผิดพลาด',
    'err_retry': 'กรุณาลองใหม่อีกครั้ง',
    'no_barcode': 'ไม่พบบาร์โค้ด',
    'no_barcode_detail': 'ระบบไม่พบบาร์โค้ดในรูปภาพนี้',
    'no_object': 'ไม่พบวัตถุ',
    'no_object_detail': 'วิเคราะห์ไม่ได้ กรุณาลองใหม่',
    'origin': 'ประเทศต้นทาง',
    'select_action': 'เลือกสิ่งที่ต้องการทำด้านล่าง',
    'bin_yellow': 'ทิ้งถังเหลือง (รีไซเคิล)',
    'bin_green': 'ทิ้งถังเขียว (ขยะเปียก)',
    'bin_red': 'ทิ้งถังแดง (ขยะอันตราย)',
    'bin_blue': 'ทิ้งถังน้ำเงิน (ขยะทั่วไป)',
    'dialog_title': 'ไม่พบข้อมูลรายการนี้ ✨',
    'dialog_code': 'รหัส',
    'dialog_name_hint': 'ชื่อรายการ (เช่น ขวดน้ำ, กระป๋อง)',
    'dialog_packaging_hint': 'วัสดุบรรจุภัณฑ์ (ไม่บังคับ)',
    'dialog_packaging_placeholder': 'เช่น พลาสติก, กระดาษ, แก้ว, อลูมิเนียม',
    'dialog_select_bin': 'เลือกประเภทถังขยะ:',
    'dialog_bin_recycle': 'รีไซเคิล',
    'dialog_bin_general': 'ทั่วไป',
    'dialog_bin_wet': 'ขยะเปียก',
    'dialog_bin_hazard': 'อันตราย',
    'dialog_cancel': 'ยกเลิก',
    'dialog_save': 'บันทึก',
    'dialog_thank': '🙏 ขอบคุณที่ช่วยเพิ่มข้อมูลครับ!',
    'material': 'วัสดุ',
    'code': 'รหัส',
    'sheet_unknown_name': 'ไม่ทราบชื่อรายการ',
    'sheet_auto_source': 'ดึงจาก API อัตโนมัติ',
    'sheet_user_source': 'รอตรวจสอบ (ผู้ใช้เพิ่ม)',
    'sheet_ai_source': 'รอตรวจสอบ (AI วิเคราะห์)',
  };

  static const Map<String, String> _stringsEn = {
    'mode_barcode': 'Barcode',
    'mode_ai': 'AI Scan',
    'overlay_barcode_mode': 'Barcode Mode',
    'overlay_ai_mode': 'AI Mode',
    'overlay_barcode_hint': 'Point camera at barcode',
    'overlay_ai_hint': 'Align waste item in frame',
    'gallery': 'Gallery',
    'confidence': 'Confidence',
    'confidence_ai': 'AI Confidence',
    'more_results': 'Show more results',
    'not_found_title': 'Item not found',
    'not_found_action': 'What would you like to do?',
    'btn_add_manual': 'Add manually',
    'btn_ai_help': 'Let AI help',
    'err_slow_network': 'Slow network',
    'err_slow_detail': 'No response from server.\nPlease try again.',
    'err_generic': 'An error occurred',
    'err_retry': 'Please try again',
    'no_barcode': 'No barcode found',
    'no_barcode_detail': 'No barcode detected in this image.',
    'no_object': 'No object found',
    'no_object_detail': 'Could not analyze. Please try again.',
    'origin': 'Country of origin',
    'select_action': 'Choose an option below',
    'bin_yellow': 'Yellow bin (Recyclable)',
    'bin_green': 'Green bin (Wet waste)',
    'bin_red': 'Red bin (Hazardous)',
    'bin_blue': 'Blue bin (General waste)',
    'dialog_title': 'Item not found ✨',
    'dialog_code': 'Code',
    'dialog_name_hint': 'Item name (e.g. Water bottle, Can)',
    'dialog_packaging_hint': 'Packaging material (optional)',
    'dialog_packaging_placeholder': 'e.g. Plastic, Paper, Glass, Aluminium',
    'dialog_select_bin': 'Select bin type:',
    'dialog_bin_recycle': 'Recycle',
    'dialog_bin_general': 'General',
    'dialog_bin_wet': 'Wet waste',
    'dialog_bin_hazard': 'Hazardous',
    'dialog_cancel': 'Cancel',
    'dialog_save': 'Save',
    'dialog_thank': '🙏 Thank you for contributing!',
    'material': 'Material',
    'code': 'Code',
    'sheet_unknown_name': 'Unknown item',
    'sheet_auto_source': 'Fetched from API automatically',
    'sheet_user_source': 'Pending review (user added)',
    'sheet_ai_source': 'Pending review (AI analyzed)',
  };

  @override
  void dispose() {
    cameraController.dispose();
    super.dispose();
  }

  void _reset({bool full = false}) => setState(() {
    isScanning = true;
    isLoading = false;
    _rawResult = null;
    _rColor = Colors.white;
    _rIcon = Icons.info;
    _rScore = '';
    aiResults = [];
    _tempScannedCode = null;
    _consecutiveReads = 0;
    _notFoundCode = null;
    if (full) _imageFile = null;
  });

  void _switchMode(ScanMode mode) {
    setState(() => currentMode = mode);
    _reset(full: true);
  }

  // แทน _setResult เดิม ด้วย raw data
  // notFoundCode: ถ้า set จะ assign _notFoundCode ใน setState เดียวกัน (Fix 3: no double setState)
  void _setRawResult(Map<String, dynamic> raw, {String? notFoundCode}) {
    if (!mounted) return;
    setState(() {
      _rawResult = raw;
      _rColor = raw['color'] as Color? ?? Colors.grey;
      _rIcon = raw['icon'] as IconData? ?? Icons.info;
      _rScore = raw['score'] as String? ?? '0%';
      isLoading = false;
      if (notFoundCode != null) _notFoundCode = notFoundCode;
    });
  }

  bool _isValidBarcode(String code) {
    if (!RegExp(r'^[0-9]+$').hasMatch(code)) return false;
    if (code.length < 8 || code.length > 14) return false;
    if (code.length == 13) {
      int sum = 0;
      for (int i = 0; i < 12; i++)
        sum += int.parse(code[i]) * (i % 2 == 0 ? 1 : 3);
      if ((10 - (sum % 10)) % 10 != int.parse(code[12])) return false;
    }
    return true;
  }

  String _classifyByBarcodeRange(String code) {
    if (code.length < 3) return 'Unknown';
    final prefix = code.substring(0, 3);
    if (prefix == '885') return 'Thailand';
    if (prefix == '890') return 'India';
    if (prefix == '880') return 'South Korea';
    if (code.startsWith('45') || code.startsWith('49')) return 'Japan';
    if (code.startsWith('69')) return 'China';
    return 'Unknown';
  }

  // Fix #5: cap cache เพื่อป้องกัน memory leak ใน session ยาว
  static const int _maxCacheSize = 100;

  void _addToCache(String code, Map<String, dynamic> data) {
    if (_barcodeCache.length >= _maxCacheSize) {
      _barcodeCache.remove(_barcodeCache.keys.first);
    }
    _barcodeCache[code] = data;
  }

  static Color _binColor(String binKey) {
    switch (binKey) {
      case 'bin_yellow':
        return Colors.yellow;
      case 'bin_green':
        return Colors.green;
      case 'bin_red':
        return Colors.red;
      default:
        return Colors.blue;
    }
  }

  static IconData _binIcon(String binKey) {
    switch (binKey) {
      case 'bin_yellow':
        return Icons.recycling;
      case 'bin_green':
        return Icons.restaurant;
      case 'bin_red':
        return Icons.dangerous;
      default:
        return Icons.delete_outline;
    }
  }

  Future<void> _saveToGoogleSheet(
    String code,
    String name,
    String pkg,
    String inst,
    Color color,
    String country,
    String source,
  ) async {
    if (googleSheetUrl.isEmpty || googleSheetUrl == 'ไม่พบ URL') return;
    String colorString = 'blue';
    if (color == Colors.yellow)
      colorString = 'yellow';
    else if (color == Colors.green)
      colorString = 'green';
    else if (color == Colors.red)
      colorString = 'red';
    else if (color == Colors.grey)
      colorString = 'grey';

    try {
      await http
          .post(
            Uri.parse(googleSheetUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'barcode': code,
              'productName': name,
              'packaging': pkg,
              'instruction': inst,
              'binColor': colorString,
              'country': country,
              'source': source,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('❌ Sheet Save Error: $e');
    }
  }

  void _showAddProductDialog(String code) {
    if (!mounted) return;
    final nameController = TextEditingController();
    final packagingController = TextEditingController();

    // Fix #1: dispose controllers เมื่อ dialog ปิด
    void disposeControllers() {
      nameController.dispose();
      packagingController.dispose();
    }

    Color selectedColor = Colors.blue;

    // Fix 2: whenComplete ครอบคลุมทุก dismiss path:
    // ปุ่ม "ยกเลิก", ปุ่ม "บันทึก", และ Android back button
    // ไม่ต้อง call disposeControllers() ในแต่ละปุ่มแล้ว
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Colors.grey[900],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            _t('dialog_title'),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${_t('dialog_code')}: $code',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 15),
                _buildTextField(nameController, _t('dialog_name_hint')),
                const SizedBox(height: 12),
                _buildTextField(
                  packagingController,
                  _t('dialog_packaging_hint'),
                  hint: _t('dialog_packaging_placeholder'),
                ),
                const SizedBox(height: 20),
                Text(
                  _t('dialog_select_bin'),
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _colorChoiceBtn(
                      Colors.yellow,
                      _t('dialog_bin_recycle'),
                      selectedColor,
                      () => setDialogState(() => selectedColor = Colors.yellow),
                    ),
                    _colorChoiceBtn(
                      Colors.blue,
                      _t('dialog_bin_general'),
                      selectedColor,
                      () => setDialogState(() => selectedColor = Colors.blue),
                    ),
                    _colorChoiceBtn(
                      Colors.green,
                      _t('dialog_bin_wet'),
                      selectedColor,
                      () => setDialogState(() => selectedColor = Colors.green),
                    ),
                    _colorChoiceBtn(
                      Colors.red,
                      _t('dialog_bin_hazard'),
                      selectedColor,
                      () => setDialogState(() => selectedColor = Colors.red),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.spaceBetween,
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _reset(full: true);
              },
              child: Text(
                _t('dialog_cancel'),
                style: const TextStyle(color: Colors.white54),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.tealAccent,
              ),
              onPressed: () {
                if (nameController.text.trim().isEmpty) return;

                String binKey = 'bin_blue';
                if (selectedColor == Colors.yellow)
                  binKey = 'bin_yellow';
                else if (selectedColor == Colors.green)
                  binKey = 'bin_green';
                else if (selectedColor == Colors.red)
                  binKey = 'bin_red';

                final pkg = packagingController.text.trim().isEmpty
                    ? '-'
                    : packagingController.text.trim();

                // อ่านค่าก่อน pop (controller ยังยังไม่ dispose ณ จุดนี้)
                final name = nameController.text.trim();
                Navigator.pop(
                  context,
                ); // whenComplete จะ disposeControllers หลัง pop

                _saveToGoogleSheet(
                  code,
                  name,
                  pkg,
                  _t(binKey),
                  selectedColor,
                  _classifyByBarcodeRange(code),
                  _t('sheet_user_source'),
                );
                _setRawResult({
                  'source': 'user',
                  'name': name,
                  'binKey': binKey,
                  'color': selectedColor,
                  'icon': _binIcon(binKey),
                  'score': '100%',
                });
              },
              child: Text(
                _t('dialog_save'),
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    ).whenComplete(disposeControllers); // Fix 2: guaranteed dispose ทุก path
  }

  Widget _buildTextField(
    TextEditingController ctrl,
    String label, {
    String? hint,
  }) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white54),
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
        enabledBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Colors.white24),
        ),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Colors.tealAccent),
        ),
      ),
    );
  }

  Widget _colorChoiceBtn(
    Color c,
    String label,
    Color selectedColor,
    VoidCallback onTap,
  ) {
    final isSelected = selectedColor == c;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? c.withValues(alpha: 0.2) : Colors.transparent,
          border: Border.all(color: isSelected ? c : Colors.white24, width: 2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, color: c, size: 16),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? c : Colors.white70,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> onBarcodeDetect(BarcodeCapture capture) async {
    if (currentMode != ScanMode.barcode || !isScanning || _hasResult) return;
    if (capture.barcodes.isEmpty || capture.barcodes.first.rawValue == null)
      return;

    final code = capture.barcodes.first.rawValue!;
    if (!_isValidBarcode(code)) {
      _consecutiveReads = 0;
      return;
    }

    if (code == _tempScannedCode) {
      _consecutiveReads++;
    } else {
      _tempScannedCode = code;
      _consecutiveReads = 1;
    }
    if (_consecutiveReads < 3) return;

    if (_lastBarcodeRequestAt != null &&
        DateTime.now().difference(_lastBarcodeRequestAt!) < _barcodeCooldown)
      return;
    _lastBarcodeRequestAt = DateTime.now();

    // Bug fix #1: cache เก็บ raw data → render ตอนแสดงผล
    if (_barcodeCache.containsKey(code)) {
      final cached = _barcodeCache[code]!;
      _setRawResult({
        'source': 'cache',
        'name': cached['name'],
        'packaging': cached['packaging'],
        'binKey': cached['binKey'],
        'code': code,
        'color': cached['color'],
        'icon': cached['icon'],
        'score': '100%',
      });
      return;
    }

    if (mounted)
      setState(() {
        isScanning = false;
        isLoading = true;
        _consecutiveReads = 0;
      });
    await _lookupBarcode(code);
  }

  Future<void> _lookupBarcode(String code) async {
    final country = _classifyByBarcodeRange(code);

    // ยิง parallel
    final results = await Future.wait([
      _fetchOpenFoodFacts(code),
      _fetchGoogleSheet(code),
    ]);

    final offResult = results[0];
    final sheetResult = results[1];
    if (!mounted) return;

    // Sheet มีข้อมูล → ใช้ก่อน
    if (sheetResult != null) {
      _setRawResult({
        'source': 'sheet',
        'name': sheetResult['productName'],
        'packaging': sheetResult['packaging'],
        'instruction': sheetResult['instruction'],
        'code': code,
        'color': sheetResult['color'],
        'icon': sheetResult['icon'],
        'score': '100%',
      });
      return;
    }

    // OFF มีข้อมูล
    if (offResult != null) {
      final productName = offResult['productName'] as String;
      final packaging = offResult['packaging'] as String;

      // classify packaging
      String binKey = 'bin_blue';
      if (packaging.toLowerCase().contains(
        RegExp(
          r'plastic|pet|polyethylene|polypropylene|polystyrene|pvc|hdpe|ldpe'
          r'|พลาสติก|aluminium|aluminum|can|tin|metal|กระป๋อง'
          r'|paper|cardboard|carton|กล่อง|กระดาษ|glass|แก้ว|bottle|bag',
        ),
      )) {
        binKey = 'bin_yellow';
      }

      // Fix #5: ใช้ _addToCache แทน direct assignment
      _addToCache(code, {
        'name': productName,
        'packaging': packaging,
        'binKey': binKey,
        'color': _binColor(binKey),
        'icon': _binIcon(binKey),
      });

      _setRawResult({
        'source': 'off',
        'name': productName,
        'packaging': packaging,
        'binKey': binKey,
        'code': code,
        'color': _binColor(binKey),
        'icon': _binIcon(binKey),
        'score': '100%',
      });

      // save to sheet fire-and-forget
      _saveToGoogleSheet(
        code,
        productName,
        packaging,
        _t(binKey),
        _binColor(binKey),
        country,
        _t('sheet_auto_source'),
      );
      return;
    }

    // ไม่พบ → result card + action buttons (Fix 3: รวม setState เป็นครั้งเดียว)
    if (!mounted) return;
    _setRawResult({
      'source': 'not_found',
      'code': code,
      'country': country,
      'color': Colors.orange,
      'icon': Icons.search_off,
      'score': '0%',
    }, notFoundCode: code);
  }

  Future<Map<String, dynamic>?> _fetchOpenFoodFacts(String code) async {
    try {
      final url = Uri.parse(
        'https://world.openfoodfacts.org/api/v0/product/$code.json',
      );
      final res = await http.get(url).timeout(_offApiTimeout);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['status'] == 1) {
          final p = data['product'] as Map<String, dynamic>;

          final productName =
              p['product_name_th'] ??
              p['product_name'] ??
              _t('sheet_unknown_name');

          // ---- แก้: ดึง packaging จากหลาย field + decode slug ----
          final packaging = _extractPackaging(p);

          return {'productName': productName as String, 'packaging': packaging};
        }
      }
    } on TimeoutException {
      debugPrint('⏱️ OpenFoodFacts timeout: $code');
    } catch (e) {
      debugPrint('❌ OpenFoodFacts error: $e');
    }
    return null;
  }

  /// ดึง packaging จาก OFF response อย่างครบถ้วน
  /// ลำดับ priority: packaging_text_th → packaging_text_en → packaging_tags → packaging (slug)
  String _extractPackaging(Map<String, dynamic> p) {
    // 1. human-readable Thai
    final textTh = (p['packaging_text_th'] as String?)?.trim();
    if (textTh != null && textTh.isNotEmpty) return textTh;

    // 2. human-readable English
    final textEn = (p['packaging_text_en'] as String?)?.trim();
    if (textEn != null && textEn.isNotEmpty) return textEn;

    // 3. packaging_tags array → clean slugs
    final tags = p['packaging_tags'];
    if (tags is List && tags.isNotEmpty) {
      final cleaned = tags
          .map((t) => _decodeOffSlug(t.toString()))
          .where((t) => t.isNotEmpty)
          .toSet() // กัน duplicate
          .toList();
      if (cleaned.isNotEmpty) return cleaned.join(', ');
    }

    // 4. packaging string → clean slugs (fallback)
    final raw = (p['packaging'] as String?)?.trim();
    if (raw != null && raw.isNotEmpty) {
      final cleaned = raw
          .split(',')
          .map((t) => _decodeOffSlug(t.trim()))
          .where((t) => t.isNotEmpty)
          .toSet()
          .toList();
      if (cleaned.isNotEmpty) return cleaned.join(', ');
    }

    return ''; // ไม่มีข้อมูล
  }

  /// แปลง OFF slug → ข้อความอ่านได้
  /// "en:plastic-bag" → "Plastic bag"
  /// "th:พลาสติก" → "พลาสติก"
  String _decodeOffSlug(String slug) {
    // ลบ language prefix เช่น "en:", "th:", "fr:"
    final noPrefix = slug.replaceAll(RegExp(r'^[a-z]{2}:'), '').trim();
    if (noPrefix.isEmpty) return '';
    // แปลง hyphen → space แล้ว capitalize
    final words = noPrefix.split('-');
    return words
        .map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  Future<Map<String, dynamic>?> _fetchGoogleSheet(String code) async {
    if (googleSheetUrl.isEmpty) return null;
    try {
      final res = await http
          .get(Uri.parse('$googleSheetUrl?barcode=$code'))
          .timeout(_sheetApiTimeout);
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body);
        if (d['status'] == 'success') {
          String binKey = 'bin_blue';
          switch (d['binColor']) {
            case 'yellow':
              binKey = 'bin_yellow';
              break;
            case 'green':
              binKey = 'bin_green';
              break;
            case 'red':
              binKey = 'bin_red';
              break;
          }
          return {
            'productName': d['productName'],
            'instruction': d['instruction'],
            'packaging': d['packaging'],
            'color': _binColor(binKey),
            'icon': _binIcon(binKey),
          };
        }
      }
    } on TimeoutException {
      debugPrint('⏱️ Google Sheet timeout: $code');
    } catch (e) {
      debugPrint('❌ Google Sheet error: $e');
    }
    return null;
  }

  Future<void> _processImage(ImageSource source) async {
    if (isLoading) return;
    setState(() => isScanning = false);
    final photo = await ImagePicker().pickImage(source: source, maxWidth: 800);
    if (photo == null) {
      if (pendingBarcode != null) pendingBarcode = null;
      _reset();
      return;
    }
    setState(() {
      _imageFile = photo;
      isLoading = true;
      _rawResult = null;
      isScanning = false; // Fix #4: หยุด camera scan ระหว่าง process image
    });
    try {
      if (currentMode == ScanMode.barcode) {
        final capture = await cameraController.analyzeImage(photo.path);
        // Fix 1: ไม่เรียก onBarcodeDetect เพราะมี guard !isScanning (สำหรับ live camera เท่านั้น)
        // แทนด้วยการ extract code และเรียก _lookupBarcode โดยตรง
        final rawValue =
            (capture is BarcodeCapture && capture.barcodes.isNotEmpty)
            ? capture.barcodes.first.rawValue
            : null;

        if (rawValue != null && _isValidBarcode(rawValue)) {
          // Check cache ก่อนเหมือน live camera path
          if (_barcodeCache.containsKey(rawValue)) {
            final cached = _barcodeCache[rawValue]!;
            _setRawResult({
              'source': 'cache',
              'name': cached['name'],
              'packaging': cached['packaging'],
              'binKey': cached['binKey'],
              'code': rawValue,
              'color': cached['color'],
              'icon': cached['icon'],
              'score': '100%',
            });
          } else {
            // isLoading already true from outer setState above
            await _lookupBarcode(rawValue);
          }
        } else {
          _setRawResult({
            'source': 'no_barcode',
            'color': Colors.grey,
            'icon': Icons.qr_code_scanner,
            'score': '0%',
          });
        }
      } else {
        final base64Image = await compute(_encodeImageToBase64Sync, photo.path);
        final uri = Uri.parse(
          'https://vision.googleapis.com/v1/images:annotate?key=$apiKey',
        );
        final res = await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'requests': [
                  {
                    'image': {'content': base64Image},
                    'features': [
                      {'type': 'LABEL_DETECTION'},
                      {'type': 'LOGO_DETECTION'},
                    ],
                  },
                ],
              }),
            )
            .timeout(_visionApiTimeout);

        if (res.statusCode == 200) {
          _analyzeAIMultiple(jsonDecode(res.body));
        } else {
          throw Exception('Server Error ${res.statusCode}');
        }
      }
    } on TimeoutException {
      if (pendingBarcode != null) pendingBarcode = null;
      _setRawResult({
        'source': 'timeout',
        'color': Colors.orange,
        'icon': Icons.wifi_off,
        'score': '0%',
      });
    } catch (e) {
      if (pendingBarcode != null) pendingBarcode = null;
      _setRawResult({
        'source': 'error',
        'errMsg': e.toString(),
        'color': Colors.red,
        'icon': Icons.error,
        'score': '0%',
      });
    }
  }

  static String _encodeImageToBase64Sync(String path) =>
      base64Encode(File(path).readAsBytesSync());

  void _analyzeAIMultiple(Map<String, dynamic> json) {
    final res = json['responses']?[0] ?? {};
    final List<dynamic> labels = res['labelAnnotations'] ?? [];

    if (labels.isEmpty) {
      if (pendingBarcode != null) pendingBarcode = null;
      _setRawResult({
        'source': 'no_object',
        'color': Colors.grey,
        'icon': Icons.close,
        'score': '0%',
      });
      return;
    }

    // Fix 4: aiResults = [] อยู่นอก setState โดยเจตนา — ปลอดภัยเพราะ:
    // 1. Dart single-threaded, ไม่มี race condition
    // 2. _setRawResult ที่เรียกถัดไปจะ rebuild UI อยู่แล้ว
    // 3. ถ้าใส่ใน setState จะต้อง move for-loop ทั้งหมดเข้าไปด้วย ซึ่งหนักเกินไป
    aiResults = [];
    final usedBinTypes = <String>{};
    for (final labelItem in labels) {
      if (aiResults.length >= 5) break;
      final label = labelItem['description'] as String? ?? 'Unknown';
      final score = (labelItem['score'] as num? ?? 0) * 100;
      if (_isJustColor(label.toLowerCase()) ||
          _isHumanRelated(label.toLowerCase()))
        continue;

      // Bug fix #3: store binKey แทน translated string
      final result = _classifyWaste(label, score);
      final typeKey = '${result['title']}_${result['binKey']}';
      if (!usedBinTypes.contains(typeKey)) {
        usedBinTypes.add(typeKey);
        aiResults.add(result);
      }
    }

    if (aiResults.isNotEmpty) {
      if (pendingBarcode != null) {
        final top = aiResults.first;
        final savedCode = pendingBarcode!;
        _saveToGoogleSheet(
          savedCode,
          top['title'] as String,
          '-',
          _t(top['binKey'] as String),
          top['binColor'] as Color,
          _classifyByBarcodeRange(savedCode),
          _t('sheet_ai_source'),
        );
        pendingBarcode = null;
        // Fix #2: ส่ง savedCode เข้าไปใน rawResult ตั้งแต่แรก ไม่ต้อง mutate ภายหลัง
        _setRawResult({
          'source': 'ai',
          'name': top['title'],
          'binKey': top['binKey'],
          'color': top['binColor'],
          'icon': top['icon'],
          'score': top['score'],
          'savedCode': savedCode,
        });
      } else {
        _displayAIResult(0);
      }
    } else {
      if (pendingBarcode != null) pendingBarcode = null;
      _setRawResult({
        'source': 'no_object',
        'color': Colors.grey,
        'icon': Icons.close,
        'score': '0%',
      });
    }
  }

  // Bug fix #3: return binKey ไม่ใช่ translated detail
  Map<String, dynamic> _classifyWaste(String label, double score) {
    final l = label.toLowerCase();
    final s = '${score.toStringAsFixed(2)}%';
    if (l.contains(
      RegExp(
        r'bottle|plastic|glass|metal|can|tin|container|cup|fluid|drinking water|beverage|liquid',
      ),
    ))
      return {
        'title': label,
        'binKey': 'bin_yellow',
        'score': s,
        'binColor': Colors.yellow,
        'icon': Icons.recycling,
      };
    if (l.contains(RegExp(r'paper|cardboard|box|carton')))
      return {
        'title': label,
        'binKey': 'bin_yellow',
        'score': s,
        'binColor': Colors.yellow,
        'icon': Icons.recycling,
      };
    if (l.contains(RegExp(r'food|fruit|vegetable|bread|bakery|meat')))
      return {
        'title': label,
        'binKey': 'bin_green',
        'score': s,
        'binColor': Colors.green,
        'icon': Icons.restaurant,
      };
    if (_isHazardous(l))
      return {
        'title': label,
        'binKey': 'bin_red',
        'score': s,
        'binColor': Colors.red,
        'icon': Icons.dangerous,
      };
    return {
      'title': label,
      'binKey': 'bin_blue',
      'score': s,
      'binColor': Colors.blue,
      'icon': Icons.help_outline,
    };
  }

  bool _isHazardous(String t) => [
    'battery',
    'spray',
    'insecticide',
    'chemical',
    'paint',
    'oil',
    'toxic',
    'electronic',
    'phone',
    'mobile',
    'computer',
    'fan',
    'bulb',
    'appliance',
  ].any(t.contains);
  bool _isJustColor(String t) => [
    'silver',
    'gold',
    'black',
    'white',
    'red',
    'blue',
    'green',
    'yellow',
    'color',
  ].any(t.contains);
  bool _isHumanRelated(String t) => [
    'person',
    'human',
    'face',
    'smile',
    'eye',
    'hair',
    'floor',
    'flooring',
    'furniture',
    'bedding',
    'linens',
    'wall',
    'indoor',
  ].any(t.contains);

  void _displayAIResult(int index, {String? pendingCode}) {
    final result = aiResults[index];
    _setRawResult({
      'source': 'ai',
      'name': result['title'],
      'binKey': result['binKey'],
      'color': result['binColor'],
      'icon': result['icon'],
      'score': result['score'],
    });
    // ถ้ามี pendingCode (กด result จาก modal ขณะที่มาจาก barcode not found)
    if (pendingCode != null) {
      _saveToGoogleSheet(
        pendingCode,
        result['title'] as String,
        '-',
        _t(result['binKey'] as String),
        result['binColor'] as Color,
        _classifyByBarcodeRange(pendingCode),
        _t('sheet_ai_source'),
      );
    }
  }

  void _showMoreResultsModal() {
    // เก็บ barcode code ที่ save ไว้ก่อน เปิด modal (ถ้ามี)
    final savedCode = _rawResult?['savedCode'] as String?;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => ListView.builder(
        itemCount: aiResults.length,
        itemBuilder: (ctx, index) {
          final result = aiResults[index];
          final binKey = result['binKey'] as String;
          return ListTile(
            leading: Icon(
              result['icon'] as IconData,
              color: result['binColor'] as Color,
            ),
            title: Text(
              result['title'] as String,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Text(
              _t(binKey),
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            trailing: Text(
              result['score'] as String,
              style: TextStyle(
                color: result['binColor'] as Color,
                fontWeight: FontWeight.bold,
              ),
            ),
            onTap: () {
              // ส่ง savedCode ให้ save ไป Sheet ด้วยถ้าผู้ใช้เลือก result อื่น
              _displayAIResult(index, pendingCode: savedCode);
              Navigator.pop(ctx);
            },
          );
        },
      ),
    );
  }

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
          if (_imageFile == null && !_hasResult) _buildScannerOverlay(),
          Positioned(top: 50, left: 20, right: 20, child: _buildHeader()),
          if (isLoading)
            const Center(
              child: CircularProgressIndicator(color: Colors.tealAccent),
            ),
          if (_hasResult) _buildResultCard(),
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: frameColor.withValues(alpha: 0.2),
              border: Border.all(color: frameColor, width: 1),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Text(
              isBarcode ? _t('overlay_barcode_mode') : _t('overlay_ai_mode'),
              style: TextStyle(
                color: frameColor,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Container(
            width: 280,
            height: isBarcode ? 150 : 280,
            decoration: BoxDecoration(
              border: Border.all(color: frameColor, width: 2),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          const SizedBox(height: 15),
          Text(
            isBarcode ? _t('overlay_barcode_hint') : _t('overlay_ai_hint'),
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
        'WasteVision',
        style: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      Row(
        children: [
          // Bug fix #8: ปุ่มสลับภาษา + persist
          GestureDetector(
            onTap: _toggleLanguage,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white24),
              ),
              child: Text(
                _isEnglish ? '🇹🇭 ไทย' : '🇬🇧 ENG',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
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
        child: Container(
          padding: const EdgeInsets.all(20),
          color: Colors.black87,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_rIcon, color: _rColor, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _displayTitle, // Bug fix #5
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: _rColor,
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
                _displayDetail, // Bug fix #5
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
                        ? _t('confidence')
                        : _t('confidence_ai'),
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  Text(
                    _rScore,
                    style: TextStyle(
                      color: _rColor,
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
                  value:
                      (double.tryParse(_rScore.replaceAll('%', '')) ?? 0) / 100,
                  color: _rColor,
                  backgroundColor: Colors.white10,
                  minHeight: 6,
                ),
              ),
              if (aiResults.length > 1) ...[
                const SizedBox(height: 15),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _showMoreResultsModal,
                    icon: const Icon(Icons.list),
                    label: Text(
                      '${_t('more_results')} (${aiResults.length - 1})',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.tealAccent,
                      foregroundColor: Colors.black,
                    ),
                  ),
                ),
              ],
              if (_notFoundCode != null) ...[
                const SizedBox(height: 16),
                const Divider(color: Colors.white12),
                const SizedBox(height: 8),
                Text(
                  _t('not_found_action'),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.edit, size: 16),
                        label: Text(_t('btn_add_manual')),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.tealAccent,
                          side: const BorderSide(color: Colors.tealAccent),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        onPressed: () {
                          final code = _notFoundCode!;
                          setState(() => _notFoundCode = null);
                          _showAddProductDialog(code);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.auto_awesome, size: 16),
                        label: Text(_t('btn_ai_help')),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.tealAccent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        onPressed: () {
                          pendingBarcode = _notFoundCode;
                          _switchMode(ScanMode.ai);
                          _processImage(ImageSource.camera);
                        },
                      ),
                    ),
                  ],
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
                      Text(
                        _t('gallery'),
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: SizedBox(
                      width: 75,
                      height: 75,
                      child: (currentMode == ScanMode.ai && !_hasResult)
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
                  _modeBtn(_t('mode_barcode'), ScanMode.barcode),
                  _modeBtn(_t('mode_ai'), ScanMode.ai),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeBtn(String txt, ScanMode m) {
    final active = currentMode == m;
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
