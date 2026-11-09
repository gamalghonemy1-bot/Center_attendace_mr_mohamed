import 'package:flutter/material.dart';

import '../db.dart';
import '../ui.dart';
import 'session_detail_screen.dart';

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});
  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  DateTime _day = DateTime.now();
  List<DbRow> _items = [];

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
    final r = await AppDb.instance.sessionsOnDate(fmtDate(_day));
    if (mounted) setState(() => _items = r);
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      _day = d;
      _load();
    }
  }

  void _shift(int days) {
    _day = DateTime(_day.year, _day.month, _day.day + days);
    _load();
  }

  Future<void> _addExtra() async {
    final groups = await AppDb.instance.groups();
    if (!mounted) return;
    if (groups.isEmpty) {
      toast(context, 'أضف مجموعة أولاً');
      return;
    }
    int groupId = groups.first['id'] as int;
    DateTime date = _day;
    String start = (groups.first['start_time'] as String);
    String end = (groups.first['end_time'] as String);
    String? error;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('حصة إضافية / تعويضية'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<int>(
                value: groupId,
                decoration: const InputDecoration(labelText: 'المجموعة'),
                items: [
                  for (final g in groups)
                    DropdownMenuItem(
                        value: g['id'] as int, child: Text(g['name'] as String))
                ],
                onChanged: (v) => setD(() {
                  groupId = v ?? groupId;
                  final g = groups.firstWhere((x) => x['id'] == groupId);
                  start = g['start_time'] as String;
                  end = g['end_time'] as String;
                }),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_today),
                title: Text(fmtDate(date)),
                onTap: () async {
                  final d = await showDatePicker(
                      context: ctx,
                      initialDate: date,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100));
                  if (d != null) setD(() => date = d);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule),
                title: Text('البداية: ${fmt12(start)}'),
                onTap: () async {
                  final t = await showTimePicker(
                      context: ctx, initialTime: parseTime(start));
                  if (t != null) setD(() => start = fmtTimeOfDay(t));
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule_outlined),
                title: Text('النهاية: ${fmt12(end)}'),
                onTap: () async {
                  final t = await showTimePicker(
                      context: ctx, initialTime: parseTime(end));
                  if (t != null) setD(() => end = fmtTimeOfDay(t));
                },
              ),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.red)),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                if (end.compareTo(start) <= 0) {
                  setD(() => error = 'وقت النهاية يجب أن يكون بعد البداية');
                } else {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final added =
        await AppDb.instance.addExtraSession(groupId, fmtDate(date), start, end);
    if (!mounted) return;
    if (!added) {
      toast(context, 'توجد حصة لنفس المجموعة في نفس الوقت');
    } else {
      _day = date;
      _load();
    }
  }

  Widget _chip(SessionState st) {
    final (label, color) = switch (st) {
      SessionState.upcoming => ('قادمة', Colors.orange),
      SessionState.active => ('مفتوحة', Colors.green),
      SessionState.ended => ('منتهية', Colors.grey),
      SessionState.canceled => ('ملغاة', Colors.red),
    };
    return Chip(
      label: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 12)),
      backgroundColor: color,
      visualDensity: VisualDensity.compact,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('حصص اليوم'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(
                onPressed: () => _shift(-1),
                icon: const Icon(Icons.chevron_right)),
            TextButton.icon(
              onPressed: _pickDay,
              icon: const Icon(Icons.calendar_month),
              label: Text(
                  '${weekdayNames[_day.weekday]}  ${fmtDate(_day)}'),
            ),
            IconButton(
                onPressed: () => _shift(1),
                icon: const Icon(Icons.chevron_left)),
          ]),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addExtra,
        icon: const Icon(Icons.add),
        label: const Text('حصة تعويضية'),
      ),
      body: _items.isEmpty
          ? const Center(
              child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'لا توجد حصص في هذا اليوم.\nالحصص تُولَّد تلقائياً من جدول كل مجموعة.',
                textAlign: TextAlign.center,
              ),
            ))
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final s = _items[i];
                final st = sessionState(s);
                return ListTile(
                  title: Text(s['group_name'] as String),
                  subtitle: Text(
                      '${fmt12(s['start_time'] as String)} – ${fmt12(s['end_time'] as String)}   •   حضور ${s['present_count']}/${s['total']}'),
                  leading: _chip(st),
                  trailing: ((s['extra'] as int?) ?? 0) == 1
                      ? const Text('تعويضية')
                      : null,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            SessionDetailScreen(sessionId: s['id'] as int)),
                  ),
                );
              },
            ),
    );
  }
}
