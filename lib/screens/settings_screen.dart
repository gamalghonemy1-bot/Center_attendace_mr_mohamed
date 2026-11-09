import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../db.dart';
import '../ui.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _teacher = TextEditingController();
  final TextEditingController _cc = TextEditingController(text: '20');
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    dataVersion.addListener(_loadSettings);
    _loadSettings();
  }

  @override
  void dispose() {
    dataVersion.removeListener(_loadSettings);
    _teacher.dispose();
    _cc.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final t = await AppDb.instance.getMeta('teacher_name', '');
    final c = await AppDb.instance.getMeta('country_code', '20');
    if (!mounted) return;
    _teacher.text = t;
    _cc.text = c;
  }

  Future<void> _saveSettings() async {
    final cc = _cc.text.replaceAll(RegExp(r'[^0-9]'), '');
    await AppDb.instance.setMeta('teacher_name', _teacher.text.trim());
    await AppDb.instance.setMeta('country_code', cc.isEmpty ? '20' : cc);
    if (mounted) toast(context, 'تم حفظ الإعدادات');
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) toast(context, 'حدث خطأ: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveToDevice() => _run(() async {
        final f = await AppDb.instance.createBackupFile();
        final bytes = await f.readAsBytes();
        final path = await FilePicker.platform.saveFile(
          dialogTitle: 'حفظ النسخة الاحتياطية',
          fileName: f.uri.pathSegments.last,
          bytes: bytes,
        );
        if (!mounted) return;
        toast(context, path == null ? 'أُلغي الحفظ' : 'تم حفظ النسخة الاحتياطية');
      });

  Future<void> _share() => _run(() async {
        final f = await AppDb.instance.createBackupFile();
        await Share.shareXFiles([XFile(f.path)], text: 'نسخة احتياطية - حضور السنتر');
      });

  Future<void> _restore() async {
    final ok = await confirmDialog(context,
        'ستُستبدل كل البيانات الحالية بمحتوى النسخة المختارة. هل تريد المتابعة؟');
    if (!ok) return;
    await _run(() async {
      final res = await FilePicker.platform.pickFiles(type: FileType.any);
      final path = res?.files.single.path;
      if (path == null) return;
      await AppDb.instance.restoreFrom(path);
      if (mounted) toast(context, 'تمت استعادة البيانات بنجاح');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('رسائل أولياء الأمور',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _teacher,
          decoration: const InputDecoration(
            labelText: 'اسمك أو اسم السنتر (يظهر في ذيل الرسالة)',
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _cc,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'مفتاح الدولة (مصر 20)',
            helperText:
                'الرقم الذي يبدأ بـ 0 مثل 0101... يتحول تلقائياً إلى 20101...',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _saveSettings,
          icon: const Icon(Icons.save),
          label: const Text('حفظ الإعدادات'),
        ),
        const Divider(height: 40),
        Text('النسخ الاحتياطي والاستعادة',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text(
          'البيانات محفوظة على هذا الهاتف فقط. خذ نسخة احتياطية بانتظام '
          'واحفظها خارج الهاتف (واتساب، البريد، الملفات، ...).',
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _saveToDevice,
          icon: const Icon(Icons.save_alt),
          label: const Text('حفظ نسخة احتياطية في ملف'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy ? null : _share,
          icon: const Icon(Icons.share),
          label: const Text('مشاركة نسخة احتياطية'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy ? null : _restore,
          icon: const Icon(Icons.restore),
          label: const Text('استعادة من ملف نسخة احتياطية'),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
      ]),
    );
  }
}
