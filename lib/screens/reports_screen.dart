import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../db.dart';
import '../ui.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  List<DbRow> _groups = [];
  int? _groupId;
  int _year = DateTime.now().year;
  int _month = DateTime.now().month;
  int _sessions = 0;
  List<DbRow> _rows = [];
  bool _busy = false;
  final Set<int> _sent = {};

  @override
  void initState() {
    super.initState();
    dataVersion.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    dataVersion.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final gs = await AppDb.instance.groups();
    int? gid = _groupId;
    if (gid == null || !gs.any((g) => g['id'] == gid)) {
      gid = gs.isEmpty ? null : gs.first['id'] as int;
    }
    var sessions = 0;
    List<DbRow> rows = [];
    if (gid != null) {
      final rep = await AppDb.instance.monthlyReport(gid, _year, _month);
      sessions = rep.sessions;
      rows = rep.rows;
    }
    if (!mounted) return;
    setState(() {
      _groups = gs;
      _groupId = gid;
      _sessions = sessions;
      _rows = rows;
    });
  }

  void _shiftMonth(int d) {
    var m = _month + d;
    var y = _year;
    if (m < 1) {
      m = 12;
      y--;
    } else if (m > 12) {
      m = 1;
      y++;
    }
    _month = m;
    _year = y;
    _sent.clear();
    _load();
  }

  String _groupName() {
    for (final g in _groups) {
      if (g['id'] == _groupId) return g['name'] as String;
    }
    return '';
  }

  int _n(DbRow r, String k) => (r[k] as int?) ?? 0;

  List<String> _absentDates(DbRow r) {
    final raw = (r['absent_dates'] as String?) ?? '';
    if (raw.isEmpty) return [];
    final list = raw.split(',');
    list.sort();
    return list;
  }

  String _pct(DbRow r) {
    final p = _n(r, 'present');
    final a = _n(r, 'absent');
    if (p + a == 0) return '—';
    return '${(p * 100 / (p + a)).round()}%';
  }

  Future<void> _notify(DbRow r) async {
    final msg = await monthlyMessage(
      student: r['name'] as String,
      group: _groupName(),
      year: _year,
      month: _month,
      present: _n(r, 'present'),
      absent: _n(r, 'absent'),
      absentDates: _absentDates(r),
    );
    if (!mounted) return;
    await sendWhatsApp(context, r['parent_phone'] as String?, msg);
    if (mounted) setState(() => _sent.add(r['id'] as int));
  }

  String _html() {
    final b = StringBuffer();
    var i = 0;
    for (final r in _rows) {
      i++;
      final dates = _absentDates(r).join(' ، ');
      b.write('<tr><td>$i</td><td>${esc(r['name'] as String)}</td>'
          '<td>${_n(r, 'present')}</td><td>${_n(r, 'absent')}</td>'
          '<td>${_pct(r)}</td><td class="d">${esc(dates)}</td></tr>');
    }
    return '''
<html dir="rtl" lang="ar"><head><meta charset="utf-8"><style>
body{font-family:sans-serif;direction:rtl;padding:12px}
h1{font-size:20px;text-align:center;margin:0 0 4px}
h2{font-size:14px;text-align:center;margin:0 0 12px;color:#444;font-weight:normal}
table{width:100%;border-collapse:collapse;font-size:12px}
th,td{border:1px solid #666;padding:5px;text-align:center}
th{background:#d6e4f5}.d{font-size:10px;direction:ltr}
tr{page-break-inside:avoid}
</style></head><body>
<h1>تقرير الحضور والغياب الشهري</h1>
<h2>المجموعة: ${esc(_groupName())} — ${arabicMonths[_month - 1]} $_year — عدد الحصص: $_sessions</h2>
<table><tr><th>#</th><th>اسم الطالب</th><th>حضور</th><th>غياب</th><th>النسبة</th><th>تواريخ الغياب</th></tr>
$b</table></body></html>''';
  }

  Future<void> _pdf({required bool share}) async {
    if (_rows.isEmpty) {
      toast(context, 'لا توجد بيانات لهذه المجموعة');
      return;
    }
    setState(() => _busy = true);
    try {
      final bytes = await Printing.convertHtml(html: _html());
      final name = 'report_${_year}_${_month.toString().padLeft(2, '0')}.pdf';
      if (share) {
        await Printing.sharePdf(bytes: bytes, filename: name);
      } else {
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: name);
      }
    } catch (e) {
      if (mounted) toast(context, 'تعذّر إنشاء التقرير: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('التقارير الشهرية')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: DropdownButtonFormField<int>(
            value: _groupId,
            decoration: const InputDecoration(labelText: 'المجموعة'),
            items: [
              for (final g in _groups)
                DropdownMenuItem(
                    value: g['id'] as int, child: Text(g['name'] as String)),
            ],
            onChanged: (v) {
              _groupId = v;
              _sent.clear();
              _load();
            },
          ),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(
              onPressed: () => _shiftMonth(-1),
              icon: const Icon(Icons.chevron_right)),
          Text('${arabicMonths[_month - 1]} $_year',
              style: Theme.of(context).textTheme.titleMedium),
          IconButton(
              onPressed: () => _shiftMonth(1),
              icon: const Icon(Icons.chevron_left)),
        ]),
        Text('الحصص المنتهية في الشهر: $_sessions'),
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Text(
            'اضغط أيقونة واتساب بجانب الطالب لإرسال تقريره لولي أمره.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        const Divider(),
        Expanded(
          child: _rows.isEmpty
              ? const Center(child: Text('لا توجد بيانات'))
              : ListView.builder(
                  itemCount: _rows.length,
                  itemBuilder: (_, i) {
                    final r = _rows[i];
                    final sid = r['id'] as int;
                    final hasPhone =
                        ((r['parent_phone'] as String?) ?? '').trim().isNotEmpty;
                    return ListTile(
                      title: Text(r['name'] as String),
                      subtitle: Text(
                          'حضور ${_n(r, 'present')}   غياب ${_n(r, 'absent')}   •   ${_pct(r)}'),
                      trailing: IconButton(
                        tooltip: hasPhone
                            ? 'إرسال التقرير لولي الأمر (واتساب)'
                            : 'لا يوجد رقم لولي الأمر',
                        icon: Icon(
                          _sent.contains(sid) ? Icons.mark_chat_read : Icons.chat,
                          color: !hasPhone
                              ? Colors.grey
                              : (_sent.contains(sid)
                                  ? Colors.green
                                  : Colors.teal),
                        ),
                        onPressed: () => _notify(r),
                      ),
                    );
                  },
                ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _pdf(share: false),
                  icon: const Icon(Icons.print),
                  label: const Text('عرض / طباعة PDF'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _pdf(share: true),
                  icon: const Icon(Icons.share),
                  label: const Text('مشاركة PDF'),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
