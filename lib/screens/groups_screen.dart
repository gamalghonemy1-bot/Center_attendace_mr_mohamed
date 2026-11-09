import 'package:flutter/material.dart';

import '../db.dart';
import '../ui.dart';

class GroupsScreen extends StatefulWidget {
  const GroupsScreen({super.key});
  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> {
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
    final r = await AppDb.instance.groups();
    if (mounted) setState(() => _items = r);
  }

  Future<void> _form([DbRow? g]) async {
    final name = TextEditingController(text: (g?['name'] as String?) ?? '');
    final days = <int>{...parseDays((g?['days'] as String?) ?? '')};
    String start = (g?['start_time'] as String?) ?? '16:00';
    String end = (g?['end_time'] as String?) ?? '18:00';
    String? error;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(g == null ? 'مجموعة جديدة' : 'تعديل المجموعة'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: name,
                autofocus: g == null,
                decoration: const InputDecoration(
                    labelText: 'اسم المجموعة (مثال: ثالثة ثانوي - أ)'),
              ),
              const SizedBox(height: 12),
              const Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text('أيام المجموعة')),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final d in weekOrder)
                  FilterChip(
                    label: Text(weekdayNames[d]!),
                    selected: days.contains(d),
                    onSelected: (v) => setD(() {
                      if (v) {
                        days.add(d);
                      } else {
                        days.remove(d);
                      }
                    }),
                  ),
              ]),
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
                if (name.text.trim().isEmpty) {
                  setD(() => error = 'أدخل اسم المجموعة');
                } else if (days.isEmpty) {
                  setD(() => error = 'اختر يوماً واحداً على الأقل');
                } else if (end.compareTo(start) <= 0) {
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
    final list = days.toList();
    if (g == null) {
      await AppDb.instance.addGroup(name.text.trim(), list, start, end);
    } else {
      await AppDb.instance
          .updateGroup(g['id'] as int, name.text.trim(), list, start, end);
    }
  }

  Future<void> _delete(DbRow g) async {
    final ok = await confirmDialog(context,
        'حذف المجموعة "${g['name']}" سيحذف طلابها وحصصها وسجلات حضورها. متابعة؟');
    if (ok) await AppDb.instance.deleteGroup(g['id'] as int);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('المجموعات')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _form(),
        child: const Icon(Icons.add),
      ),
      body: _items.isEmpty
          ? const Center(child: Text('لا توجد مجموعات. أضف مجموعة للبدء.'))
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final g = _items[i];
                return ListTile(
                  title: Text(g['name'] as String),
                  subtitle: Text(
                      '${scheduleText(g)}\nعدد الطلاب: ${g['students_count']}'),
                  isThreeLine: true,
                  onTap: () => _form(g),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(g),
                  ),
                );
              },
            ),
    );
  }
}
