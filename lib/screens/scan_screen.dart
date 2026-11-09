import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../db.dart';

class ScanScreen extends StatefulWidget {
  final int sessionId;
  final String title;
  const ScanScreen({super.key, required this.sessionId, required this.title});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _busy = false;
  String? _lastCode;
  DateTime _lastAt = DateTime(2000);
  String _msg = 'وجّه الكاميرا نحو رمز الطالب';
  Color _color = Colors.blueGrey;
  int _present = 0;

  int get _sid => widget.sessionId;

  @override
  void initState() {
    super.initState();
    AppDb.instance.presentCount(_sid).then((n) {
      if (mounted) setState(() => _present = n);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture cap) async {
    if (_busy) return;
    String? raw;
    for (final b in cap.barcodes) {
      final v = b.rawValue;
      if (v != null && v.startsWith('ATT:')) {
        raw = v;
        break;
      }
    }
    if (raw == null) return;
    final now = DateTime.now();
    if (raw == _lastCode && now.difference(_lastAt) < const Duration(seconds: 3)) {
      return;
    }
    _busy = true;
    _lastCode = raw;
    _lastAt = now;

    final out = await AppDb.instance.recordScan(_sid, raw.substring(4));
    final count = await AppDb.instance.presentCount(_sid);
    if (!mounted) return;

    String msg;
    Color color;
    switch (out.result) {
      case ScanResult.ok:
        msg = '✔ تم تسجيل حضور: ${out.name}';
        color = Colors.green;
        HapticFeedback.mediumImpact();
      case ScanResult.duplicate:
        msg = 'تم تسجيل ${out.name} مسبقاً';
        color = Colors.orange;
        HapticFeedback.heavyImpact();
      case ScanResult.wrongGroup:
        msg = '${out.name} ليس من هذه المجموعة';
        color = Colors.red;
        HapticFeedback.heavyImpact();
      case ScanResult.notFound:
        msg = 'رمز غير معروف';
        color = Colors.red;
        HapticFeedback.heavyImpact();
      case ScanResult.closed:
        msg = 'الحصة ليست جارية الآن';
        color = Colors.red;
        HapticFeedback.heavyImpact();
    }
    setState(() {
      _msg = msg;
      _color = color;
      _present = count;
    });
    await Future<void>.delayed(const Duration(milliseconds: 700));
    _busy = false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            width: double.infinity,
            color: _color,
            padding: const EdgeInsets.all(16),
            child: SafeArea(
              top: false,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_msg,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('الحاضرون: $_present',
                    style: const TextStyle(color: Colors.white)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}
