import 'package:flutter/material.dart';

import '../db.dart';
import '../ui.dart';
import 'scan_screen.dart';

class SessionDetailScreen extends StatefulWidget {
  final int sessionId;
  const SessionDetailScreen({super.key, required this.sessionId});
  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  DbRow? _session;
  List<DbRow> _roster = [];
  final Set<int> _notified = {};

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
    final s = await AppDb.instance.sessionById(widget.sessionId);
    if (s == null) {
      if (mounted) Navigator.maybePop(context);
      return;
    }
    final r = await AppDb.instance.roster(widget.sessionId, s['group_id'] as int);
    if (mounted) {
      setState(() {
        _session = s;
        _roster = r;
      });
    }
  }

  Future<void> _notifyAbsent(DbRow r) async {
    final s = _session;
    if (s == null) return;
    final msg = await absenceMessage(
      student: r['name'] as String,
      group: s['group_name'] as String,
      date: s['date'] as String,
      startTime: s['start_time'] as String,
    );
    if (!mounted) return;
    await sendWhatsApp(context, r['parent_phone'] as String?, msg);
    if (mounted) setState(() => _notified.add(r['id'] as int));
  }

  Future<void> _toggleCancel() async {
    final s = _session;
    if (s == null) return;
    final canceled = ((s['canceled'] as int?) ?? 0) == 1;
    final ok = await confirmDialog(
        context,
        canceled
            ? 'استعادة هذه الحصة؟'
            : 'إلغاء هذه الحصة (إجازة)؟ لن تُحتسب في الغياب ولا في التقارير.');
    if (ok) await AppDb.instance.setCanceled(widget.sessionId, !canceled);
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    if (s == null) {
      return Scaffold(
          appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    final st = sessionState(s);
    final present = _roster.where((r) => r['status'] == 'present').length;
    final absent = _roster.where((r) => r['status'] == 'absent').length;
    return Scaffold(
      appBar: AppBar(
        title: Text('${s['group_name']}'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'cancel') _toggleCancel();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'cancel',
                  child: Text(st == SessionState.canceled
                      ? 'استعادة الحصة'
                      : 'إلغاء الحصة (إجازة)')),
            ],
          ),
        ],
      ),
      floatingActionButton: st == SessionState.active
          ? FloatingActionButton.extended(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => ScanScreen(
                        sessionId: widget.sessionId,
                        title: '${s['group_name']}')),
              ),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('مسح QR'),
            )
          : null,
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '${weekdayNames[DateTime.parse(s['date'] as String).weekday]} ${s['date']}   '
            '${fmt12(s['start_time'] as String)} – ${fmt12(s['end_time'] as String)}\n'
            'حاضر: $present    غائب: $absent    الإجمالي: ${_roster.length}',
            textAlign: TextAlign.center,
          ),
        ),
        if (st == SessionState.canceled)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('هذه الحصة ملغاة ولا تُحتسب.',
                style: TextStyle(color: Colors.red)),
          ),
        if (st == SessionState.upcoming)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
                'يفتح تسجيل الحضور قبل البداية بـ $earlyScanMinutes دقيقة.'),
          ),
        if (st == SessionState.ended)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('انتهت الحصة وسُجّل الغياب تلقائياً. يمكنك التعديل يدوياً.'),
          ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: _roster.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final r = _roster[i];
              final status = r['status'] as String?;
              final (label, color) = switch (status) {
                'present' => ('حاضر', Colors.green),
                'absent' => ('غائب', Colors.red),
                _ => ('لم يُسجَّل', Colors.grey),
              };
              final sid = r['id'] as int;
              return ListTile(
                title: Text(r['name'] as String),
                subtitle: Text(label, style: TextStyle(color: color)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (status == 'absent')
                    IconButton(
                      tooltip: 'إخطار ولي الأمر بالغياب (واتساب)',
                      icon: Icon(Icons.chat,
                          color: _notified.contains(sid)
                              ? Colors.green
                              : Colors.teal),
                      onPressed: () => _notifyAbsent(r),
                    ),
                  PopupMenuButton<String>(
                    onSelected: (v) =>
                        AppDb.instance.setStatus(widget.sessionId, sid, v),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'present', child: Text('تسجيل حاضر')),
                      PopupMenuItem(value: 'absent', child: Text('تسجيل غائب')),
                    ],
                  ),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }
}
