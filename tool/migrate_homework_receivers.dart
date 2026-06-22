import 'dart:convert';
import 'dart:io';

const _adminTeacherUids = <String>{
  '40Jo9GaY7yXyx5jlur0R4K7COuo1',
  'bx3V05SRysTn2PBYU7PQrcF1fyY2',
  'ewYMeMDCkXU4sRhemweN7IiTINy1',
};

void main(List<String> args) {
  final opts = _Args.parse(args);
  if (opts.help || opts.inputPath.isEmpty) {
    _printUsage();
    exit(opts.help ? 0 : 64);
  }

  final input = File(opts.inputPath);
  if (!input.existsSync()) {
    stderr.writeln('Input file not found: ${opts.inputPath}');
    exit(66);
  }

  final root = _asMap(jsonDecode(input.readAsStringSync()));
  final report = _migrate(root, write: opts.write);

  stdout.writeln('Scanned homework receiver migration candidates.');
  stdout.writeln('Candidates: ${report.candidates}');
  stdout.writeln('Changed attendance rows: ${report.attendanceRowsChanged}');
  stdout.writeln(
    'Changed class attendance rows: ${report.classAttendanceRowsChanged}',
  );
  stdout.writeln('Moved threads: ${report.threadsMoved}');
  stdout.writeln('Skipped: ${report.skipped}');
  if (report.notes.isNotEmpty) {
    stdout.writeln('\nDetails:');
    for (final note in report.notes) {
      stdout.writeln(note);
    }
  }

  if (!opts.write) {
    stdout.writeln(
      '\nDry-run only. Re-run with --write --output <path> to write a migrated JSON file.',
    );
    return;
  }

  if (opts.outputPath.isEmpty) {
    stderr.writeln('--output is required when using --write.');
    exit(64);
  }

  final output = File(opts.outputPath);
  output.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(root));
  stdout.writeln('\nWrote migrated JSON: ${opts.outputPath}');
}

_Report _migrate(Map<String, dynamic> root, {required bool write}) {
  final report = _Report();
  final users = _asMap(root['users']);
  final classes = _asMap(root['classes']);
  final mailThreads = _asMap(root['mail_threads']);
  final mailMessages = _asMap(root['mail_messages']);
  final mailIndex = _asMap(root['mail_index']);
  final mailState = _asMap(root['mail_state']);

  for (final userEntry in users.entries) {
    final learnerUid = userEntry.key;
    final user = _asMap(userEntry.value);
    final courses = _asMap(user['courses']);
    if (courses.isEmpty) continue;

    final learnerName = _userName(user, fallback: 'Learner');

    for (final courseEntry in courses.entries) {
      final courseKey = courseEntry.key;
      final course = _asMap(courseEntry.value);
      final attendance = _asMap(course['attendance']);
      if (attendance.isEmpty) continue;

      for (final attEntry in attendance.entries) {
        final sessionId = attEntry.key;
        final rec = _asMap(attEntry.value);
        final homework = _asMap(rec['homework']);
        if (homework.isEmpty) continue;

        final oldUid = _str(rec['teacherUid']);
        if (!_adminTeacherUids.contains(oldUid)) continue;

        report.candidates++;

        final classId = _str(rec['class_id']);
        final classNode = _asMap(classes[classId]);
        final current = _asMap(classNode['instructor_current']);
        final newUid = _str(current['uid']);
        final newName = _str(current['name']);

        if (classId.isEmpty || classNode.isEmpty) {
          report.skip(
            'SKIP no class: learner=$learnerUid course=$courseKey session=$sessionId class=$classId old=$oldUid',
          );
          continue;
        }
        if (newUid.isEmpty || _adminTeacherUids.contains(newUid)) {
          report.skip(
            'SKIP no non-admin current teacher: learner=$learnerUid course=$courseKey session=$sessionId class=$classId old=$oldUid current=$newUid',
          );
          continue;
        }

        final oldThreadId = '${learnerUid}_${oldUid}_$sessionId';
        final newThreadId = '${learnerUid}_${newUid}_$sessionId';
        report.notes.add(
          'MOVE learner=$learnerUid course=$courseKey session=$sessionId class=$classId old=$oldUid new=$newUid oldThread=$oldThreadId newThread=$newThreadId',
        );

        if (!write) continue;

        rec['teacherUid'] = newUid;
        rec['teacherName'] = newName;
        attendance[sessionId] = rec;
        course['attendance'] = attendance;
        courses[courseKey] = course;
        user['courses'] = courses;
        users[learnerUid] = user;
        report.attendanceRowsChanged++;

        final classAttendance = _asMap(classNode['attendance']);
        final classRec = _asMap(classAttendance[sessionId]);
        if (_adminTeacherUids.contains(_str(classRec['teacherUid']))) {
          classRec['teacherUid'] = newUid;
          classRec['teacherName'] = newName;
          classAttendance[sessionId] = classRec;
          classNode['attendance'] = classAttendance;
          classes[classId] = classNode;
          report.classAttendanceRowsChanged++;
        }

        final homeworkRef =
            'users/$learnerUid/courses/$courseKey/attendance/$sessionId/homework';
        final subject = _str(
          mailThreads[oldThreadId] is Map
              ? _asMap(mailThreads[oldThreadId])['subject']
              : null,
        );
        final lastMessage = _str(
          mailThreads[oldThreadId] is Map
              ? _asMap(mailThreads[oldThreadId])['lastMessage']
              : null,
        );
        final updatedAt = mailThreads[oldThreadId] is Map
            ? _asMap(mailThreads[oldThreadId])['updatedAt']
            : rec['updatedAt'];

        if (mailThreads.containsKey(oldThreadId)) {
          mailThreads[newThreadId] = _rewriteThread(
            _asMap(mailThreads[oldThreadId]),
            oldUid: oldUid,
            newUid: newUid,
            learnerUid: learnerUid,
            sessionId: sessionId,
            courseKey: courseKey,
            homeworkRef: homeworkRef,
          );
          mailThreads.remove(oldThreadId);
        }

        if (mailMessages.containsKey(oldThreadId)) {
          mailMessages[newThreadId] = _rewriteMessages(
            _asMap(mailMessages[oldThreadId]),
            oldUid: oldUid,
            newUid: newUid,
          );
          mailMessages.remove(oldThreadId);
        }

        _moveIndexRow(
          mailIndex,
          ownerUid: learnerUid,
          oldOwnerUid: oldUid,
          newOwnerUid: newUid,
          oldThreadId: oldThreadId,
          newThreadId: newThreadId,
          peerUid: newUid,
          peerName: newName.isEmpty ? 'Teacher' : newName,
          peerRole: 'teacher',
          homeworkRef: homeworkRef,
          subjectFallback: subject,
          lastMessageFallback: lastMessage,
          updatedAtFallback: updatedAt,
        );
        _moveIndexRow(
          mailIndex,
          ownerUid: newUid,
          oldOwnerUid: oldUid,
          newOwnerUid: newUid,
          oldThreadId: oldThreadId,
          newThreadId: newThreadId,
          peerUid: learnerUid,
          peerName: learnerName,
          peerRole: 'learner',
          homeworkRef: homeworkRef,
          subjectFallback: subject,
          lastMessageFallback: lastMessage,
          updatedAtFallback: updatedAt,
        );
        final oldAdminRows = _asMap(mailIndex[oldUid]);
        oldAdminRows.remove(oldThreadId);
        mailIndex[oldUid] = oldAdminRows;

        _moveState(mailState, learnerUid, oldThreadId, newThreadId);
        _moveState(
          mailState,
          oldUid,
          oldThreadId,
          newThreadId,
          newOwnerUid: newUid,
        );

        report.threadsMoved++;
      }
    }
  }

  if (write) {
    root['users'] = users;
    root['mail_threads'] = mailThreads;
    root['mail_messages'] = mailMessages;
    root['mail_index'] = mailIndex;
    root['mail_state'] = mailState;
  }

  return report;
}

Map<String, dynamic> _rewriteThread(
  Map<String, dynamic> src, {
  required String oldUid,
  required String newUid,
  required String learnerUid,
  required String sessionId,
  required String courseKey,
  required String homeworkRef,
}) {
  final out = _deepCopyMap(src);
  final participants = _asMap(out['participants']);
  participants.remove(oldUid);
  participants[newUid] = true;
  participants[learnerUid] = true;
  out['participants'] = participants;
  out['teacherUid'] = newUid;
  out['homeworkOwnerTeacherUid'] = newUid;
  out['learnerUid'] = learnerUid;
  out['homeworkLearnerUid'] = learnerUid;
  out['sessionId'] = sessionId;
  out['courseKey'] = courseKey;
  out['homeworkRef'] = homeworkRef;
  out['type'] = 'homework';
  return out;
}

Map<String, dynamic> _rewriteMessages(
  Map<String, dynamic> src, {
  required String oldUid,
  required String newUid,
}) {
  final out = _deepCopyMap(src);
  for (final entry in out.entries.toList()) {
    final msg = _asMap(entry.value);
    if (msg.isEmpty) continue;
    for (final key in const [
      'toUids',
      'ccUids',
      'bccUids',
      'readBy',
      'deliveredTo',
    ]) {
      final m = _asMap(msg[key]);
      if (m.remove(oldUid) != null) m[newUid] = true;
      if (m.isNotEmpty) msg[key] = m;
    }
    if (_str(msg['fromUid']) == oldUid) msg['fromUid'] = newUid;
    out[entry.key] = msg;
  }
  return out;
}

void _moveIndexRow(
  Map<String, dynamic> mailIndex, {
  required String ownerUid,
  required String oldOwnerUid,
  required String newOwnerUid,
  required String oldThreadId,
  required String newThreadId,
  required String peerUid,
  required String peerName,
  required String peerRole,
  required String homeworkRef,
  required String subjectFallback,
  required String lastMessageFallback,
  required dynamic updatedAtFallback,
}) {
  final ownerRows = _asMap(mailIndex[ownerUid]);
  final oldOwnerRows = _asMap(mailIndex[oldOwnerUid]);
  final source = _asMap(ownerRows[oldThreadId]).isNotEmpty
      ? _asMap(ownerRows[oldThreadId])
      : _asMap(oldOwnerRows[oldThreadId]);
  final row = source.isEmpty ? <String, dynamic>{} : _deepCopyMap(source);
  row['peerUid'] = peerUid;
  row['peerName'] = peerName;
  row['peerRole'] = peerRole;
  row['type'] = 'homework';
  row['homeworkRef'] = homeworkRef;
  row['deletedAt'] = null;
  if (_str(row['subject']).isEmpty && subjectFallback.isNotEmpty) {
    row['subject'] = subjectFallback;
  }
  if (_str(row['lastMessage']).isEmpty && lastMessageFallback.isNotEmpty) {
    row['lastMessage'] = lastMessageFallback;
  }
  row['updatedAt'] ??= updatedAtFallback;

  final targetRows = _asMap(mailIndex[ownerUid]);
  targetRows[newThreadId] = row;
  targetRows.remove(oldThreadId);
  mailIndex[ownerUid] = targetRows;

  if (oldOwnerUid != newOwnerUid && ownerUid == newOwnerUid) {
    final oldRows = _asMap(mailIndex[oldOwnerUid]);
    oldRows.remove(oldThreadId);
    mailIndex[oldOwnerUid] = oldRows;
  }
}

void _moveState(
  Map<String, dynamic> mailState,
  String ownerUid,
  String oldThreadId,
  String newThreadId, {
  String? newOwnerUid,
}) {
  final ownerRows = _asMap(mailState[ownerUid]);
  if (!ownerRows.containsKey(oldThreadId)) return;
  final targetUid = newOwnerUid ?? ownerUid;
  final targetRows = _asMap(mailState[targetUid]);
  targetRows[newThreadId] = _deepCopy(ownerRows[oldThreadId]);
  mailState[targetUid] = targetRows;
  ownerRows.remove(oldThreadId);
  mailState[ownerUid] = ownerRows;
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map) return value.map((k, v) => MapEntry(k.toString(), v));
  return <String, dynamic>{};
}

Map<String, dynamic> _deepCopyMap(Map<String, dynamic> value) {
  return _asMap(_deepCopy(value));
}

dynamic _deepCopy(dynamic value) => jsonDecode(jsonEncode(value));

String _str(dynamic value) => (value ?? '').toString().trim();

String _userName(Map<String, dynamic> user, {required String fallback}) {
  final first = _str(user['first_name'] ?? user['firstName']);
  final last = _str(user['last_name'] ?? user['lastName']);
  final full = ('$first $last').trim();
  if (full.isNotEmpty) return full;
  final email = _str(user['email']);
  return email.isEmpty ? fallback : email;
}

void _printUsage() {
  stdout.writeln('''
Usage:
  dart run tool/migrate_homework_receivers.dart --input <full-rtdb-export.json>
  dart run tool/migrate_homework_receivers.dart --input <full-rtdb-export.json> --write --output <migrated.json>

Default mode is dry-run. It scans learner attendance homework rows whose teacherUid is one of the known admin UIDs, resolves classes/<classId>/instructor_current.uid, and reports the thread moves it would perform.
''');
}

class _Args {
  _Args({
    required this.inputPath,
    required this.outputPath,
    required this.write,
    required this.help,
  });

  final String inputPath;
  final String outputPath;
  final bool write;
  final bool help;

  static _Args parse(List<String> args) {
    var inputPath = '';
    var outputPath = '';
    var write = false;
    var help = false;
    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--input':
          if (i + 1 < args.length) inputPath = args[++i];
          break;
        case '--output':
          if (i + 1 < args.length) outputPath = args[++i];
          break;
        case '--write':
          write = true;
          break;
        case '--help':
        case '-h':
          help = true;
          break;
      }
    }
    return _Args(
      inputPath: inputPath,
      outputPath: outputPath,
      write: write,
      help: help,
    );
  }
}

class _Report {
  int candidates = 0;
  int attendanceRowsChanged = 0;
  int classAttendanceRowsChanged = 0;
  int threadsMoved = 0;
  int skipped = 0;
  final notes = <String>[];

  void skip(String note) {
    skipped++;
    notes.add(note);
  }
}
