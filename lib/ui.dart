import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'db.dart';

Future<String?> promptText(BuildContext c, String title,
    {String initial = '', String label = ''}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: c,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('حفظ')),
      ],
    ),
  );
}

Future<bool> confirmDialog(BuildContext c, String msg) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (ctx) => AlertDialog(
      content: Text(msg),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('تأكيد')),
      ],
    ),
  );
  return r ?? false;
}

void toast(BuildContext c, String m) {
  ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));
}

String fmtTimeOfDay(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

const arabicMonths = [
  'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
  'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'
];

String qrPayload(String code) => 'ATT:$code';

/// صورة PNG لرمز QR على خلفية بيضاء مع هامش.
Future<Uint8List> qrPng(String data, {double size = 480}) async {
  final painter = QrPainter(
    data: data,
    version: QrVersions.auto,
    gapless: true,
    eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
    dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square, color: Colors.black),
  );
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawRect(Rect.fromLTWH(0, 0, size, size), Paint()..color = Colors.white);
  final pad = size * 0.08;
  canvas.translate(pad, pad);
  painter.paint(canvas, Size(size - 2 * pad, size - 2 * pad));
  final img = await rec.endRecording().toImage(size.toInt(), size.toInt());
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  return bd!.buffer.asUint8List();
}

Future<File> writeTemp(String name, List<int> bytes) async {
  final dir = await getTemporaryDirectory();
  final f = File(p.join(dir.path, name));
  await f.writeAsBytes(bytes, flush: true);
  return f;
}

String esc(String s) => const HtmlEscape().convert(s);

// ---------------- الأيام والأوقات ----------------
const Map<int, String> weekdayNames = {
  1: 'الاثنين',
  2: 'الثلاثاء',
  3: 'الأربعاء',
  4: 'الخميس',
  5: 'الجمعة',
  6: 'السبت',
  7: 'الأحد',
};

/// ترتيب الأسبوع كما يُعرض (يبدأ بالسبت).
const List<int> weekOrder = [6, 7, 1, 2, 3, 4, 5];

String fmt12(String hhmm) {
  final parts = hhmm.split(':');
  final h = int.parse(parts[0]);
  final m = parts[1];
  final suffix = h >= 12 ? 'م' : 'ص';
  var h12 = h % 12;
  if (h12 == 0) h12 = 12;
  return '$h12:$m $suffix';
}

String daysText(String days) {
  final ds = parseDays(days);
  ds.sort((a, b) => weekOrder.indexOf(a).compareTo(weekOrder.indexOf(b)));
  return ds.map((d) => weekdayNames[d] ?? '').join('، ');
}

String scheduleText(DbRow g) =>
    '${daysText(g['days'] as String)} — ${fmt12(g['start_time'] as String)} إلى ${fmt12(g['end_time'] as String)}';

TimeOfDay parseTime(String hhmm) {
  final p = hhmm.split(':');
  return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
}

// ---------------- واتساب ----------------
/// يحوّل الرقم إلى الصيغة الدولية (بدون +). الرقم المحلي الذي يبدأ بـ 0 يأخذ مفتاح الدولة.
String? normalizePhone(String raw, String countryCode) {
  final buf = StringBuffer();
  for (final r in raw.runes) {
    if (r >= 0x30 && r <= 0x39) {
      buf.writeCharCode(r);
    } else if (r >= 0x0660 && r <= 0x0669) {
      buf.writeCharCode(0x30 + r - 0x0660);
    } else if (r >= 0x06F0 && r <= 0x06F9) {
      buf.writeCharCode(0x30 + r - 0x06F0);
    }
  }
  var d = buf.toString();
  if (d.startsWith('00')) {
    d = d.substring(2);
  } else if (d.startsWith('0')) {
    d = countryCode + d.substring(1);
  }
  if (d.length < 8) return null;
  return d;
}

Future<void> sendWhatsApp(
    BuildContext context, String? rawPhone, String message) async {
  if (rawPhone == null || rawPhone.trim().isEmpty) {
    toast(context, 'لا يوجد رقم لولي الأمر لهذا الطالب');
    return;
  }
  final cc = await AppDb.instance.getMeta('country_code', '20');
  final phone = normalizePhone(rawPhone, cc);
  if (phone == null) {
    if (context.mounted) toast(context, 'رقم ولي الأمر غير صالح');
    return;
  }
  final uri =
      Uri.parse('https://wa.me/$phone?text=${Uri.encodeComponent(message)}');
  var ok = false;
  try {
    ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) toast(context, 'تعذّر فتح واتساب');
}

Future<String> _sign() async {
  final n = (await AppDb.instance.getMeta('teacher_name', '')).trim();
  return n.isEmpty ? 'إدارة المجموعة' : n;
}

Future<String> monthlyMessage({
  required String student,
  required String group,
  required int year,
  required int month,
  required int present,
  required int absent,
  required List<String> absentDates,
}) async {
  final sign = await _sign();
  final total = present + absent;
  final pct = total == 0 ? 0 : (present * 100 / total).round();
  final b = StringBuffer();
  b.writeln('السلام عليكم ورحمة الله وبركاته');
  b.writeln('ولي أمر الطالب/ة: $student');
  b.writeln('تقرير الحضور لشهر ${arabicMonths[month - 1]} $year - مجموعة $group');
  b.writeln('• عدد الحصص: $total');
  b.writeln('• الحضور: $present');
  b.writeln('• الغياب: $absent');
  b.writeln('• نسبة الحضور: $pct%');
  if (absentDates.isNotEmpty) {
    final dates = absentDates.join(' ، ');
    b.writeln('• تواريخ الغياب: $dates');
  }
  b.write('مع تحيات $sign');
  return b.toString();
}

Future<String> absenceMessage({
  required String student,
  required String group,
  required String date,
  required String startTime,
}) async {
  final sign = await _sign();
  final b = StringBuffer();
  b.writeln('السلام عليكم ورحمة الله وبركاته');
  b.writeln('نحيطكم علماً بأن الطالب/ة $student تغيّب عن حصة مجموعة $group');
  b.writeln('بتاريخ $date الساعة ${fmt12(startTime)}.');
  b.writeln('برجاء الاطمئنان عليه/ها والتواصل معنا عند الحاجة.');
  b.write('مع تحيات $sign');
  return b.toString();
}
