import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  // ==========================================
  // [Zone 1] State Variables & Constants
  // ==========================================
  final String googleSheetUrl = dotenv.env['GOOGLE_SHEET_URL'] ?? '';
  final String apiKey = dotenv.env['GOOGLE_VISION_API_KEY'] ?? '';
  final MobileScannerController cameraController = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    returnImage: false,
  );

  ScanMode currentMode = ScanMode.barcode;
  bool isScanning = true,
      isLoading = false,
      isTorchOn = false,
      _isEnglish = false;
  XFile? _imageFile;
  Map<String, dynamic>? _rawResult;
  List<Map<String, dynamic>> aiResults = [];
  final Map<String, Map<String, dynamic>> _barcodeCache = {};

  String? _tempScannedCode, pendingBarcode, _notFoundCode;
  int _consecutiveReads = 0;
  DateTime? _lastBarcodeRequestAt;

  static const Duration _barcodeCooldown = Duration(seconds: 2);
  static const Duration _offApiTimeout = Duration(seconds: 8);
  static const Duration _sheetApiTimeout = Duration(seconds: 12);
  static const Duration _visionApiTimeout = Duration(seconds: 15);

  // ==========================================
  // [Zone 2] คลังคำศัพท์ (Dictionary Patterns)
  // ==========================================
  static final RegExp _yellowBinRegex = RegExp(
    r'\b(bottle|plastic|glass|metal|can|tin|container|cup|fluid|drinking water|beverage|liquid|paper|cardboard|box|carton)\b',
    caseSensitive: false,
  );
  static final RegExp _greenBinRegex = RegExp(
    r'\b(food|fruit|vegetable|bread|bakery|meat|leaf|plant|flower|grass|seafood|fish|egg|dairy|coffee|tea|rice|noodle)\b',
    caseSensitive: false,
  );
  static final RegExp _redBinRegex = RegExp(
    r'\b(battery|spray|insecticide|chemical|paint|oil|toxic|electronic|electric|phone|mobile|computer|fan|bulb|appliance|electrical|charger|lithium|cord|cable|thermometer|syringe|needle|aerosol|fluorescent|neon|toner|cartridge|razor|blade)\b',
    caseSensitive: false,
  );
  static final RegExp _excludeRegex = RegExp(
    r'\b(silver|gold|black|white|red|blue|green|yellow|color|person|human|face|smile|eye|hair|floor|flooring|furniture|bedding|linens|wall|indoor|finger|hand|nail|wrist|thumb|flesh|skin|gesture|vein|label|packaging|product|material|brand|text|logo|advertising)\b',
    caseSensitive: false,
  );

  // ==========================================
  // [Zone 3] Localization Maps
  // ==========================================
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
    'dialog_title': 'ไม่พบข้อมูลรายการนี้',
    'dialog_code': 'รหัส',
    'dialog_name_hint': 'ชื่อรายการ',
    'dialog_packaging_hint': 'วัสดุบรรจุภัณฑ์',
    'dialog_packaging_placeholder': 'เช่น พลาสติก, กระดาษ, แก้ว',
    'dialog_select_bin': 'เลือกประเภทถังขยะ:',
    'dialog_bin_recycle': 'รีไซเคิล',
    'dialog_bin_general': 'ทั่วไป',
    'dialog_bin_wet': 'ขยะเปียก',
    'dialog_bin_hazard': 'อันตราย',
    'dialog_cancel': 'ยกเลิก',
    'dialog_save': 'บันทึก',
    'dialog_thank': 'ขอบคุณที่ช่วยเพิ่มข้อมูลครับ!',
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
    'dialog_title': 'Item not found',
    'dialog_code': 'Code',
    'dialog_name_hint': 'Item name',
    'dialog_packaging_hint': 'Packaging material',
    'dialog_packaging_placeholder': 'e.g. Plastic, Paper, Glass',
    'dialog_select_bin': 'Select bin type:',
    'dialog_bin_recycle': 'Recycle',
    'dialog_bin_general': 'General',
    'dialog_bin_wet': 'Wet waste',
    'dialog_bin_hazard': 'Hazardous',
    'dialog_cancel': 'Cancel',
    'dialog_save': 'Save',
    'dialog_thank': 'Thank you for contributing!',
    'material': 'Material',
    'code': 'Code',
    'sheet_unknown_name': 'Unknown item',
    'sheet_auto_source': 'Fetched from API automatically',
    'sheet_user_source': 'Pending review (user added)',
    'sheet_ai_source': 'Pending review (AI analyzed)',
  };

  // ==========================================
  // [Zone 4] Lifecycle & State Mgmt
  // ==========================================
  @override
  void initState() {
    super.initState();
    _loadLanguagePref();
  }

  @override
  void dispose() {
    cameraController.dispose();
    super.dispose();
  }

  Future<void> _loadLanguagePref() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _isEnglish = prefs.getBool('isEnglish') ?? false);
    }
  }

  Future<void> _toggleLanguage() async {
    final newVal = !_isEnglish;
    setState(() => _isEnglish = newVal);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isEnglish', newVal);
  }

  void _reset({bool full = false}) => setState(() {
    isScanning = true;
    isLoading = false;
    _rawResult = null;
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

  void _setRawResult(Map<String, dynamic> raw, {String? notFoundCode}) {
    if (!mounted) return;
    setState(() {
      _rawResult = raw;
      isLoading = false;
      if (notFoundCode != null) _notFoundCode = notFoundCode;
    });
  }

  // ==========================================
  // [Zone 5] Data Services (Google Sheets & API)
  // ==========================================
  Future<Map<String, dynamic>?> _fetchGoogleSheet(String code) async {
    if (googleSheetUrl.isEmpty) return null;
    try {
      final res = await http
          .get(Uri.parse('$googleSheetUrl?barcode=$code'))
          .timeout(_sheetApiTimeout);
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body);
        if (d['status'] == 'success') {
          final colorKey = d['binColor']?.toString().toLowerCase() ?? 'blue';
          return {
            'productName': d['productName'],
            'instruction': d['instruction'],
            'packaging': d['packaging'],
            'binColor': colorKey,
            'sourceLabel': d['source'],
            'color': _binColor('bin_$colorKey'),
            'icon': _binIcon('bin_$colorKey'),
          };
        }
      }
    } catch (e) {
      debugPrint('❌ Sheet Error: $e');
    }
    return null;
  }

  Future<void> _saveToGoogleSheet(
    String code,
    String name,
    String pkg,
    String inst,
    Color color,
    String country,
    String sourceKey,
  ) async {
    if (googleSheetUrl.isEmpty) return;
    String colorKey = 'blue';
    if (color == Colors.yellow) {
      colorKey = 'yellow';
    } else if (color == Colors.green) {
      colorKey = 'green';
    } else if (color == Colors.red) {
      colorKey = 'red';
    }
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
              'binColor': colorKey,
              'country': country,
              'source': sourceKey,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('❌ Save Error: $e');
    }
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
          final packaging = _extractPackaging(p);
          return {'productName': productName as String, 'packaging': packaging};
        }
      }
    } catch (e) {
      debugPrint('❌ OFF Error: $e');
    }
    return null;
  }

  String _extractPackaging(Map<String, dynamic> p) {
    final textTh = (p['packaging_text_th'] as String?)?.trim();
    if (textTh != null && textTh.isNotEmpty) return textTh;
    final textEn = (p['packaging_text_en'] as String?)?.trim();
    if (textEn != null && textEn.isNotEmpty) return textEn;
    return '';
  }

  void _addToCache(String code, Map<String, dynamic> data) {
    if (_barcodeCache.length >= 100) {
      // จำกัดไว้ 100 รายการกันเครื่องอืด
      _barcodeCache.remove(_barcodeCache.keys.first);
    }
    _barcodeCache[code] = data;
  }

  // ==========================================
  // [Zone 6] AI & Classification Logic
  // ==========================================
  Map<String, dynamic> _classifyWaste(String label, double score) {
    final l = label.toLowerCase();
    String colorKey = 'blue';
    if (_yellowBinRegex.hasMatch(l)) {
      colorKey = 'yellow';
    } else if (_greenBinRegex.hasMatch(l)) {
      colorKey = 'green';
    } else if (_redBinRegex.hasMatch(l)) {
      colorKey = 'red';
    }
    final binKey = 'bin_$colorKey';
    return {
      'title': label,
      'binKey': binKey,
      'binColor': colorKey,
      'score': '${score.toStringAsFixed(2)}%',
      'color': _binColor(binKey),
      'icon': _binIcon(binKey),
    };
  }

  void _analyzeAIMultiple(Map<String, dynamic> json) {
    final res = json['responses']?[0] ?? {};
    final List<dynamic> labels = res['labelAnnotations'] ?? [];
    if (labels.isEmpty) {
      _setRawResult({
        'source': 'no_object',
        'color': Colors.grey,
        'icon': Icons.close,
      });
      return;
    }
    aiResults = [];
    final usedTypes = <String>{};
    for (final item in labels) {
      if (aiResults.length >= 5) break;
      final label = item['description'] as String? ?? '';
      final score = ((item['score'] as num?)?.toDouble() ?? 0.0) * 100;
      if (_excludeRegex.hasMatch(label)) continue;
      final result = _classifyWaste(label, score);
      if (!usedTypes.contains(result['title'])) {
        usedTypes.add(result['title']);
        aiResults.add(result);
      }
    }
    if (aiResults.isNotEmpty) {
      if (pendingBarcode != null) {
        final top = aiResults.first;
        _saveToGoogleSheet(
          pendingBarcode!,
          top['title'],
          '-',
          _t(top['binKey']),
          top['color'],
          _classifyByBarcodeRange(pendingBarcode!),
          'sheet_ai_source',
        );
        _setRawResult({
          'source': 'ai',
          'name': top['title'],
          'binColor': top['binColor'],
          'icon': top['icon'],
          'score': top['score'],
          'savedCode': pendingBarcode,
        });
        pendingBarcode = null;
      } else {
        _displayAIResult(0);
      }
    } else {
      _setRawResult({
        'source': 'no_object',
        'color': Colors.grey,
        'icon': Icons.close,
      });
    }
  }

  void _displayAIResult(int index, {String? pendingCode}) {
    final result = aiResults[index];
    _setRawResult({
      'source': 'ai',
      'name': result['title'],
      'binColor': result['binColor'],
      'icon': result['icon'],
      'score': result['score'],
    });
    if (pendingCode != null) {
      _saveToGoogleSheet(
        pendingCode,
        result['title'],
        '-',
        _t(result['binKey']),
        result['color'],
        _classifyByBarcodeRange(pendingCode),
        'sheet_ai_source',
      );
    }
  }

  // ==========================================
  // [Zone 7] UI Helpers & Details
  // ==========================================
  bool get _hasResult => _rawResult != null;
  String _t(String key) =>
      _isEnglish ? (_stringsEn[key] ?? key) : (_stringsTh[key] ?? key);

  String get _displayTitle {
    final raw = _rawResult;
    if (raw == null) return '';
    if ([
      'not_found',
      'no_barcode',
      'no_object',
      'timeout',
      'error',
    ].contains(raw['source'])) {
      return _t(raw['source'] == 'error' ? 'err_generic' : raw['source']);
    }
    return (raw['name'] as String?) ?? '';
  }

  String get _displayDetail {
    final raw = _rawResult;
    if (raw == null) return '';
    final colorKey = raw['binColor']?.toString().toLowerCase() ?? 'blue';
    final binText = _t('bin_$colorKey');
    switch (raw['source']) {
      case 'sheet':
        final sourceLabel =
            raw['sourceLabel'] as String? ?? 'sheet_auto_source';
        final specialNote = (raw['instruction'] as String?)?.isNotEmpty == true
            ? '\n💡 ${raw['instruction']}'
            : '';
        return '$binText$specialNote\n${_t(sourceLabel)}\n${_t('material')}: ${raw['packaging']}\n${_t('code')}: ${raw['code']}';
      case 'ai':
      case 'off':
      case 'cache':
      case 'user':
        return '$binText${raw['source'] == 'user' ? '\n${_t('dialog_thank')}' : ''}';
      default:
        return _t('${raw['source']}_detail');
    }
  }

  static Color _binColor(String binKey) {
    if (binKey.contains('yellow')) return Colors.yellow;
    if (binKey.contains('green')) return Colors.green;
    if (binKey.contains('red')) return Colors.red;
    return Colors.blue;
  }

  static IconData _binIcon(String binKey) {
    if (binKey.contains('yellow')) return Icons.recycling;
    if (binKey.contains('green')) return Icons.restaurant;
    if (binKey.contains('red')) return Icons.dangerous;
    return Icons.delete_outline;
  }

  bool _isValidBarcode(String code) => RegExp(r'^[0-9]{8,14}$').hasMatch(code);
  String _classifyByBarcodeRange(String code) =>
      code.startsWith('885') ? 'Thailand' : 'Unknown';

  // ==========================================
  // [Zone 8] UI Methods & Widgets
  // ==========================================
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              border: Border.all(color: frameColor, width: 1.5),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              isBarcode ? _t('overlay_barcode_mode') : _t('overlay_ai_mode'),
              style: TextStyle(
                color: frameColor,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Container(
            width: 280,
            height: isBarcode ? 150 : 280,
            decoration: BoxDecoration(
              border: Border.all(color: frameColor, width: 2.5),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            isBarcode ? _t('overlay_barcode_hint') : _t('overlay_ai_hint'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
        ),
        child: const Text(
          'WasteVision',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      Row(
        children: [
          GestureDetector(
            onTap: _toggleLanguage,
            child: Container(
              width: 90,
              height: 38,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(25),
                border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
              ),
              child: Stack(
                children: [
                  AnimatedAlign(
                    alignment: !_isEnglish
                        ? Alignment.centerLeft
                        : Alignment.centerRight,
                    duration: const Duration(milliseconds: 250),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Container(
                        width: 42,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Center(
                          child: Text(
                            'TH',
                            style: TextStyle(
                              color: !_isEnglish
                                  ? Colors.black87
                                  : Colors.white70,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            'EN',
                            style: TextStyle(
                              color: _isEnglish
                                  ? Colors.black87
                                  : Colors.white70,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          IconButton(
            icon: Icon(
              isTorchOn ? Icons.flash_on : Icons.flash_off,
              color: isTorchOn ? Colors.amber : Colors.white,
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

  Widget _buildResultCard() => Positioned(
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
                Icon(
                  _rawResult!['icon'],
                  color: _rawResult!['color'],
                  size: 28,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _displayTitle,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: _rawResult!['color'],
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
              _displayDetail,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 15),
            LinearProgressIndicator(
              value:
                  (double.tryParse(
                        _rawResult!['score']?.replaceAll('%', '') ?? '0',
                      ) ??
                      0) /
                  100,
              color: _rawResult!['color'],
              backgroundColor: Colors.white10,
            ),
            if (aiResults.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 15),
                child: SizedBox(
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
              ),
            if (_notFoundCode != null) _buildNotFoundActions(),
          ],
        ),
      ),
    ),
  );

  Widget _buildNotFoundActions() => Column(
    children: [
      const SizedBox(height: 16),
      const Divider(color: Colors.white12),
      Text(
        _t('not_found_action'),
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => _showAddProductDialog(_notFoundCode!),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.tealAccent,
                side: const BorderSide(color: Colors.tealAccent),
              ),
              child: Text(_t('btn_add_manual')),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton(
              onPressed: () {
                pendingBarcode = _notFoundCode;
                _switchMode(ScanMode.ai);
                _processImage(ImageSource.camera);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.tealAccent,
                foregroundColor: Colors.black,
              ),
              child: Text(_t('btn_ai_help')),
            ),
          ),
        ],
      ),
    ],
  );

  Widget _buildBottomControls() => Container(
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
                child: IconButton(
                  icon: const Icon(Icons.photo_library, color: Colors.white),
                  onPressed: () => _processImage(ImageSource.gallery),
                ),
              ),
              Expanded(
                child: Center(
                  child: (currentMode == ScanMode.ai && !_hasResult)
                      ? IconButton(
                          icon: const Icon(
                            Icons.camera,
                            color: Colors.white,
                            size: 40,
                          ),
                          onPressed: () => _processImage(ImageSource.camera),
                        )
                      : null,
                ),
              ),
              const Spacer(),
            ],
          ),
          Container(
            height: 50,
            margin: const EdgeInsets.only(bottom: 10),
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

  Widget _modeBtn(String txt, ScanMode m) => GestureDetector(
    onTap: () => _switchMode(m),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: currentMode == m ? Colors.tealAccent : null,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        txt,
        style: TextStyle(
          color: currentMode == m ? Colors.black : Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    ),
  );

  // --- Image Processing & Detection ---
  Future<void> onBarcodeDetect(BarcodeCapture capture) async {
    if (currentMode != ScanMode.barcode || !isScanning || _hasResult) return;
    final code = capture.barcodes.first.rawValue;
    if (code == null || !_isValidBarcode(code)) return;
    if (code == _tempScannedCode) {
      _consecutiveReads++;
    } else {
      _tempScannedCode = code;
      _consecutiveReads = 1;
    }
    if (_consecutiveReads < 3) return;
    if (_lastBarcodeRequestAt != null &&
        DateTime.now().difference(_lastBarcodeRequestAt!) < _barcodeCooldown) {
      return;
    }
    _lastBarcodeRequestAt = DateTime.now();
    // ✨ เช็คในความจำก่อน ถ้าเคยสแกนแล้วก็ดึงมาใช้เลย ไม่ต้องยิงเน็ต
    if (_barcodeCache.containsKey(code)) {
      final cached = _barcodeCache[code]!;
      _setRawResult({
        'source': 'cache',
        'name': cached['name'],
        'binColor': cached['binColor'],
        'code': code,
        'color': cached['color'],
        'icon': cached['icon'],
        'score': '100%',
      });
      return;
    }

    setState(() {
      isScanning = false;
      isLoading = true;
    });
    await _lookupBarcode(code);
  }

  Future<void> _lookupBarcode(String code) async {
    final country = _classifyByBarcodeRange(code);
    final results = await Future.wait([
      _fetchOpenFoodFacts(code),
      _fetchGoogleSheet(code),
    ]);
    final offResult = results[0];
    final sheetResult = results[1];
    if (!mounted) return;
    if (sheetResult != null) {
      // จำไว้ใช้ครั้งหน้า
      _addToCache(code, {
        'name': sheetResult['productName'],
        'binColor': sheetResult['binColor'],
        'color': sheetResult['color'],
        'icon': sheetResult['icon'],
      });
      _setRawResult({
        'source': 'sheet',
        'name': sheetResult['productName'],
        'packaging': sheetResult['packaging'],
        'instruction': sheetResult['instruction'],
        'code': code,
        'binColor': sheetResult['binColor'],
        'color': sheetResult['color'],
        'icon': sheetResult['icon'],
        'score': '100%',
      });
      return;
    }
    if (offResult != null) {
      final res = _classifyWaste(offResult['packaging'], 100.0);
      _saveToGoogleSheet(
        code,
        offResult['productName'],
        offResult['packaging'],
        _t(res['binKey']),
        res['color'],
        country,
        'sheet_auto_source',
      );
      _setRawResult({
        'source': 'off',
        'name': offResult['productName'],
        'packaging': offResult['packaging'],
        'binColor': res['binColor'],
        'binKey': res['binKey'],
        'code': code,
        'color': res['color'],
        'icon': res['icon'],
        'score': '100%',
      });
      return;
    }
    _setRawResult({
      'source': 'not_found',
      'code': code,
      'country': country,
      'color': Colors.orange,
      'icon': Icons.search_off,
      'score': '0%',
    }, notFoundCode: code);
  }

  Future<void> _processImage(ImageSource src) async {
    if (isLoading) return;
    final photo = await ImagePicker().pickImage(source: src, maxWidth: 800);
    if (photo == null) {
      _reset();
      return;
    }
    setState(() {
      _imageFile = photo;
      isLoading = true;
      isScanning = false;
    });
    try {
      if (currentMode == ScanMode.barcode) {
        final capture = await cameraController.analyzeImage(photo.path);
        final code = (capture is BarcodeCapture && capture.barcodes.isNotEmpty)
            ? capture.barcodes.first.rawValue
            : null;
        if (code != null && _isValidBarcode(code)) {
          await _lookupBarcode(code);
        } else {
          _setRawResult({
            'source': 'no_barcode',
            'color': Colors.grey,
            'icon': Icons.qr_code_scanner,
          });
        }
      } else {
        final bytes = await File(photo.path).readAsBytes();
        final res = await http
            .post(
              Uri.parse(
                'https://vision.googleapis.com/v1/images:annotate?key=$apiKey',
              ),
              body: jsonEncode({
                'requests': [
                  {
                    'image': {'content': base64Encode(bytes)},
                    'features': [
                      {'type': 'LABEL_DETECTION'},
                    ],
                  },
                ],
              }),
            )
            .timeout(_visionApiTimeout);
        if (res.statusCode == 200) _analyzeAIMultiple(jsonDecode(res.body));
      }
    } catch (e) {
      _setRawResult({
        'source': 'error',
        'color': Colors.red,
        'icon': Icons.error,
      });
    }
  }

  // --- Modals & Dialogs ---
  void _showMoreResultsModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      builder: (ctx) => ListView.builder(
        itemCount: aiResults.length,
        itemBuilder: (ctx, i) {
          final res = aiResults[i];
          return ListTile(
            leading: Icon(res['icon'], color: res['color']),
            title: Text(
              res['title'],
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Text(
              _t(res['binKey']),
              style: const TextStyle(color: Colors.white60),
            ),
            onTap: () {
              _displayAIResult(i, pendingCode: _rawResult?['savedCode']);
              Navigator.pop(ctx);
            },
          );
        },
      ),
    );
  }

  void _showAddProductDialog(String code) {
    final nCtrl = TextEditingController();
    final pCtrl = TextEditingController();
    Color selC = Colors.blue;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: Text(
            _t('dialog_title'),
            style: const TextStyle(color: Colors.white),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTextField(nCtrl, _t('dialog_name_hint')),
                const SizedBox(height: 10),
                _buildTextField(
                  pCtrl,
                  _t('dialog_packaging_hint'),
                  hint: _t('dialog_packaging_placeholder'),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 10,
                  children: [
                    _colorChoiceBtn(
                      Colors.yellow,
                      _t('dialog_bin_recycle'),
                      selC,
                      () => setS(() => selC = Colors.yellow),
                    ),
                    _colorChoiceBtn(
                      Colors.blue,
                      _t('dialog_bin_general'),
                      selC,
                      () => setS(() => selC = Colors.blue),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(_t('dialog_cancel')),
            ),
            ElevatedButton(
              onPressed: () {
                final binK = selC == Colors.yellow ? 'bin_yellow' : 'bin_blue';
                _saveToGoogleSheet(
                  code,
                  nCtrl.text,
                  pCtrl.text,
                  _t(binK),
                  selC,
                  _classifyByBarcodeRange(code),
                  'sheet_user_source',
                );
                _setRawResult({
                  'source': 'user',
                  'name': nCtrl.text,
                  'binColor': selC == Colors.yellow ? 'yellow' : 'blue',
                  'color': selC,
                  'icon': _binIcon(binK),
                });
                Navigator.pop(ctx);
              },
              child: Text(_t('dialog_save')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField(TextEditingController c, String l, {String? hint}) =>
      TextField(
        controller: c,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: l,
          hintText: hint,
          labelStyle: const TextStyle(color: Colors.white54),
          hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
        ),
      );
  Widget _colorChoiceBtn(Color c, String l, Color sel, VoidCallback t) =>
      GestureDetector(
        onTap: t,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: sel == c ? c : Colors.white24),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            l,
            style: TextStyle(color: sel == c ? c : Colors.white70),
          ),
        ),
      );
}
