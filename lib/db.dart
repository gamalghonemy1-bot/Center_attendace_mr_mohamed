import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

typedef DbRow = Map<String, Object?>;

/// يُزاد عند أي تغيير في البيانات لتحديث الشاشات.
final ValueNotifier<int> dataVersion = ValueNotifier<int>(0);
void notifyDataChanged() => dataVersion.value++;

enum ScanResult { ok, duplicate, notFound, wrongGroup, closed }

class ScanOutcome {
  final ScanResult result;
  final String? name;
  const ScanOutcome(this.result, [this.name]);
}

enum SessionState { canceled, upcoming, active, ended }

/// يُسمح بتسجيل الحضور قبل بداية الحصة بهذه المدة.
const int earlyScanMinutes = 30;

final DateFormat _dateFmt = DateFormat('yyyy-MM-dd', 'en');
String fmtDate(DateTime d) => _dateFmt.format(d);

DateTime atTime(String date, String hhmm) => DateTime.parse('$date $hhmm:00');

List<int> parseDays(String s) =>
    s.isEmpty ? <int>[] : s.split(',').map(int.parse).toList();

SessionState sessionState(DbRow s, [DateTime? now]) {
  now ??= DateTime.now();
  final canceled = (s['canceled'] as int?) ?? 0;
  if (canceled == 1) return SessionState.canceled;
  final start = atTime(s['date'] as String, s['start_time'] as String);
  final end = atTime(s['date'] as String, s['end_time'] as String);
  if (!now.isBefore(end)) return SessionState.ended;
  if (!now.isBefore(start.subtract(const Duration(minutes: earlyScanMinutes)))) {
    return SessionState.active;
  }
  return SessionState.upcoming;
}

String _newCode() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final r = Random.secure();
  return List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
}

class AppDb {
  AppDb._();
  static final AppDb instance = AppDb._();
  static const _fileName = 'center.db';

  Database? _db;
  Future<Database>? _opening;

  Future<String> get dbPath async =>
      p.join(await getDatabasesPath(), _fileName);

  Future<Database> get db {
    final cur = _db;
    if (cur != null) return Future.value(cur);
    return _opening ??= _open().then((d) {
      _db = d;
      _opening = null;
      return d;
    });
  }

  Future<Database> _open() async {
    return openDatabase(
      await dbPath,
      version: 1,
      onConfigure: (d) async {
        await d.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (d, v) async {
        await d.execute('''
          CREATE TABLE study_groups(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            days TEXT NOT NULL,
            start_time TEXT NOT NULL,
            end_time TEXT NOT NULL,
            created_at TEXT NOT NULL
          )''');
        await d.execute('''
          CREATE TABLE students(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            code TEXT NOT NULL UNIQUE,
            group_id INTEGER NOT NULL REFERENCES study_groups(id) ON DELETE CASCADE,
            parent_phone TEXT
          )''');
        await d.execute('''
          CREATE TABLE sessions(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            group_id INTEGER NOT NULL REFERENCES study_groups(id) ON DELETE CASCADE,
            date TEXT NOT NULL,
            start_time TEXT NOT NULL,
            end_time TEXT NOT NULL,
            canceled INTEGER NOT NULL DEFAULT 0,
            finalized INTEGER NOT NULL DEFAULT 0,
            extra INTEGER NOT NULL DEFAULT 0,
            UNIQUE(group_id, date, start_time)
          )''');
        await d.execute('''
          CREATE TABLE attendance(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            student_id INTEGER NOT NULL REFERENCES students(id) ON DELETE CASCADE,
            status TEXT NOT NULL,
            scanned_at TEXT,
            UNIQUE(session_id, student_id)
          )''');
        await d.execute(
            'CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)');
        await d.execute('CREATE INDEX idx_sessions_date ON sessions(date)');
      },
    );
  }

  Future<void> close() async {
    final d = _db;
    _db = null;
    _opening = null;
    await d?.close();
  }

  // ---------------- الإعدادات ----------------
  Future<String> getMeta(String key, String def) async {
    final r = await (await db).query('meta', where: 'key = ?', whereArgs: [key]);
    if (r.isEmpty) return def;
    return (r.first['value'] as String?) ?? def;
  }

  Future<void> setMeta(String key, String value) async {
    await (await db).insert('meta', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---------------- المجموعات ----------------
  Future<List<DbRow>> groups() async => (await db).rawQuery('''
        SELECT g.*,
          (SELECT COUNT(*) FROM students s WHERE s.group_id = g.id) AS students_count
        FROM study_groups g ORDER BY g.name''');

  Future<void> addGroup(
      String name, List<int> days, String start, String end) async {
    await (await db).insert('study_groups', {
      'name': name,
      'days': days.join(','),
      'start_time': start,
      'end_time': end,
      'created_at': DateTime.now().toIso8601String(),
    });
    await ensureSessions();
    notifyDataChanged();
  }

  Future<void> updateGroup(
      int id, String name, List<int> days, String start, String end) async {
    final d = await db;
    await d.update(
        'study_groups',
        {
          'name': name,
          'days': days.join(','),
          'start_time': start,
          'end_time': end,
        },
        where: 'id = ?',
        whereArgs: [id]);
    // الحصص القادمة العادية التي لم يُسجَّل فيها شيء تُولَّد من جديد بالجدول الجديد
    await d.rawDelete('''
        DELETE FROM sessions
        WHERE group_id = ? AND extra = 0 AND finalized = 0 AND date >= ?
          AND id NOT IN (SELECT session_id FROM attendance)''',
        [id, fmtDate(DateTime.now())]);
    await ensureSessions();
    notifyDataChanged();
  }

  Future<void> deleteGroup(int id) async {
    await (await db).delete('study_groups', where: 'id = ?', whereArgs: [id]);
    notifyDataChanged();
  }

  // ---------------- الطلاب ----------------
  Future<List<DbRow>> students({int? groupId}) async => (await db).rawQuery('''
        SELECT s.id, s.name, s.code, s.parent_phone, s.group_id, g.name AS group_name
        FROM students s JOIN study_groups g ON g.id = s.group_id
        ${groupId == null ? '' : 'WHERE s.group_id = ?'}
        ORDER BY s.name''', groupId == null ? [] : [groupId]);

  Future<void> addStudent(String name, int groupId, String? phone) async {
    final d = await db;
    String code;
    do {
      code = _newCode();
    } while ((await d.query('students', where: 'code = ?', whereArgs: [code]))
        .isNotEmpty);
    await d.insert('students', {
      'name': name,
      'code': code,
      'group_id': groupId,
      'parent_phone': (phone == null || phone.isEmpty) ? null : phone,
    });
    notifyDataChanged();
  }

  Future<void> updateStudent(
      int id, String name, int groupId, String? phone) async {
    await (await db).update(
        'students',
        {
          'name': name,
          'group_id': groupId,
          'parent_phone': (phone == null || phone.isEmpty) ? null : phone,
        },
        where: 'id = ?',
        whereArgs: [id]);
    notifyDataChanged();
  }

  Future<void> deleteStudent(int id) async {
    await (await db).delete('students', where: 'id = ?', whereArgs: [id]);
    notifyDataChanged();
  }

  // ---------------- الحصص ----------------
  Future<List<DbRow>> sessionsOnDate(String date) async => (await db).rawQuery('''
        SELECT s.*, g.name AS group_name,
          (SELECT COUNT(*) FROM attendance a
             WHERE a.session_id = s.id AND a.status = 'present') AS present_count,
          (SELECT COUNT(*) FROM students st WHERE st.group_id = s.group_id) AS total
        FROM sessions s JOIN study_groups g ON g.id = s.group_id
        WHERE s.date = ? ORDER BY s.start_time''', [date]);

  Future<DbRow?> sessionById(int id) async {
    final r = await (await db).rawQuery('''
        SELECT s.*, g.name AS group_name
        FROM sessions s JOIN study_groups g ON g.id = s.group_id
        WHERE s.id = ?''', [id]);
    return r.isEmpty ? null : r.first;
  }

  /// حصة إضافية/تعويضية. تُرجع false إن كانت موجودة مسبقاً بنفس الوقت.
  Future<bool> addExtraSession(
      int groupId, String date, String start, String end) async {
    final d = await db;
    final ex = await d.query('sessions',
        where: 'group_id = ? AND date = ? AND start_time = ?',
        whereArgs: [groupId, date, start]);
    if (ex.isNotEmpty) return false;
    await d.insert('sessions', {
      'group_id': groupId,
      'date': date,
      'start_time': start,
      'end_time': end,
      'canceled': 0,
      'finalized': 0,
      'extra': 1,
    });
    notifyDataChanged();
    return true;
  }

  Future<void> setCanceled(int sessionId, bool canceled) async {
    await (await db).update('sessions', {'canceled': canceled ? 1 : 0},
        where: 'id = ?', whereArgs: [sessionId]);
    notifyDataChanged();
  }

  /// يولّد حصص كل مجموعة من جدولها (من تاريخ الإنشاء حتى 14 يوماً قادمة).
  Future<void> ensureSessions() async {
    final d = await db;
    final groups = await d.query('study_groups');
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final horizon = DateTime(today.year, today.month, today.day + 14);
    final floor = DateTime(today.year, today.month, today.day - 45);
    var changed = false;
    await d.transaction((t) async {
      for (final g in groups) {
        final days = parseDays(g['days'] as String);
        final created = DateTime.parse(g['created_at'] as String);
        var day = DateTime(created.year, created.month, created.day);
        if (day.isBefore(floor)) day = floor;
        while (!day.isAfter(horizon)) {
          if (days.contains(day.weekday)) {
            final ds = fmtDate(day);
            final end = atTime(ds, g['end_time'] as String);
            // لا نولّد حصة انتهت قبل إنشاء المجموعة
            if (!end.isBefore(created)) {
              final n = await t.rawInsert('''
                INSERT OR IGNORE INTO sessions
                  (group_id, date, start_time, end_time, canceled, finalized, extra)
                VALUES (?, ?, ?, ?, 0, 0, 0)''',
                  [g['id'], ds, g['start_time'], g['end_time']]);
              if (n > 0) changed = true;
            }
          }
          day = DateTime(day.year, day.month, day.day + 1);
        }
      }
    });
    if (changed) notifyDataChanged();
  }

  Future<List<DbRow>> roster(int sessionId, int groupId) async =>
      (await db).rawQuery('''
        SELECT st.id, st.name, st.parent_phone, a.status, a.scanned_at
        FROM students st
        LEFT JOIN attendance a ON a.student_id = st.id AND a.session_id = ?
        WHERE st.group_id = ? ORDER BY st.name''', [sessionId, groupId]);

  Future<int> presentCount(int sessionId) async {
    final r = await (await db).rawQuery(
        "SELECT COUNT(*) AS n FROM attendance WHERE session_id = ? AND status = 'present'",
        [sessionId]);
    return (r.first['n'] as int?) ?? 0;
  }

  Future<void> setStatus(int sessionId, int studentId, String status) async {
    await (await db).insert(
        'attendance',
        {
          'session_id': sessionId,
          'student_id': studentId,
          'status': status,
          'scanned_at':
              status == 'present' ? DateTime.now().toIso8601String() : null,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    notifyDataChanged();
  }

  // ---------------- تسجيل الحضور ----------------
  Future<ScanOutcome> recordScan(int sessionId, String code) async {
    final d = await db;
    final ss =
        await d.query('sessions', where: 'id = ?', whereArgs: [sessionId]);
    if (ss.isEmpty) return const ScanOutcome(ScanResult.closed);
    final s = ss.first;
    if (sessionState(s) != SessionState.active) {
      return const ScanOutcome(ScanResult.closed);
    }
    final st = await d.query('students', where: 'code = ?', whereArgs: [code]);
    if (st.isEmpty) return const ScanOutcome(ScanResult.notFound);
    final stu = st.first;
    final name = stu['name'] as String;
    if (stu['group_id'] != s['group_id']) {
      return ScanOutcome(ScanResult.wrongGroup, name);
    }
    final ex = await d.query('attendance',
        where: 'session_id = ? AND student_id = ?',
        whereArgs: [sessionId, stu['id']]);
    if (ex.isNotEmpty && ex.first['status'] == 'present') {
      return ScanOutcome(ScanResult.duplicate, name);
    }
    await d.insert(
        'attendance',
        {
          'session_id': sessionId,
          'student_id': stu['id'],
          'status': 'present',
          'scanned_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    notifyDataChanged();
    return ScanOutcome(ScanResult.ok, name);
  }

  /// تسجيل الغياب تلقائياً لكل طالب لم يُسجَّل حضوره في حصة انتهت.
  Future<int> finalizeEnded() async {
    final d = await db;
    final now = DateTime.now();
    final rows =
        await d.query('sessions', where: 'finalized = 0 AND canceled = 0');
    var n = 0;
    for (final s in rows) {
      final end = atTime(s['date'] as String, s['end_time'] as String);
      if (now.isBefore(end)) continue;
      await d.transaction((t) async {
        await t.rawInsert('''
          INSERT OR IGNORE INTO attendance(session_id, student_id, status, scanned_at)
          SELECT ?, id, 'absent', NULL FROM students WHERE group_id = ?''',
            [s['id'], s['group_id']]);
        await t.update('sessions', {'finalized': 1},
            where: 'id = ?', whereArgs: [s['id']]);
      });
      n++;
    }
    if (n > 0) notifyDataChanged();
    return n;
  }

  // ---------------- التقارير ----------------
  Future<({int sessions, List<DbRow> rows})> monthlyReport(
      int groupId, int year, int month) async {
    await finalizeEnded();
    final d = await db;
    final from = '$year-${month.toString().padLeft(2, '0')}-01';
    final ny = month == 12 ? year + 1 : year;
    final nm = month == 12 ? 1 : month + 1;
    final to = '$ny-${nm.toString().padLeft(2, '0')}-01';

    final cnt = await d.rawQuery('''
        SELECT COUNT(*) AS n FROM sessions
        WHERE group_id = ? AND date >= ? AND date < ? AND finalized = 1 AND canceled = 0''',
        [groupId, from, to]);
    final rows = await d.rawQuery('''
        SELECT st.id, st.name, st.parent_phone,
          SUM(CASE WHEN x.status = 'present' THEN 1 ELSE 0 END) AS present,
          SUM(CASE WHEN x.status = 'absent' THEN 1 ELSE 0 END) AS absent,
          GROUP_CONCAT(CASE WHEN x.status = 'absent' THEN x.date END, ',') AS absent_dates
        FROM students st
        LEFT JOIN (
          SELECT a.student_id, a.status, s.date
          FROM attendance a JOIN sessions s ON s.id = a.session_id
          WHERE s.group_id = ? AND s.canceled = 0 AND s.date >= ? AND s.date < ?
        ) x ON x.student_id = st.id
        WHERE st.group_id = ?
        GROUP BY st.id ORDER BY st.name''', [groupId, from, to, groupId]);
    return (sessions: (cnt.first['n'] as int?) ?? 0, rows: rows);
  }

  // ---------------- النسخ الاحتياطي ----------------
  Future<File> createBackupFile() async {
    await db;
    await close();
    final dir = await getTemporaryDirectory();
    final stamp = DateFormat('yyyyMMdd_HHmm', 'en').format(DateTime.now());
    final out = File(p.join(dir.path, 'center_backup_$stamp.db'));
    await File(await dbPath).copy(out.path);
    return out;
  }

  Future<void> restoreFrom(String srcPath) async {
    final dir = await getTemporaryDirectory();
    final tmp = p.join(dir.path, 'restore_check.db');
    await File(srcPath).copy(tmp);
    final test = await openDatabase(tmp, readOnly: true);
    try {
      final t = await test
          .rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
      final names = t.map((e) => e['name']).toSet();
      for (final n in ['study_groups', 'students', 'sessions', 'attendance']) {
        if (!names.contains(n)) {
          throw const FormatException(
              'ملف النسخة الاحتياطية غير صالح لهذا التطبيق');
        }
      }
    } finally {
      await test.close();
    }
    await close();
    final path = await dbPath;
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final f = File('$path$suffix');
      if (await f.exists()) await f.delete();
    }
    await File(tmp).copy(path);
    notifyDataChanged();
  }
}
