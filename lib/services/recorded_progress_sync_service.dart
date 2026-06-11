import 'dart:async';
import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shared/app_connectivity.dart';

class RecordedProgressSyncService {
  RecordedProgressSyncService._();

  static final RecordedProgressSyncService instance =
      RecordedProgressSyncService._();

  static const String _prefsKey = 'recorded_progress_pending_sync_v1';
  static const String _mirrorPrefsKey = 'recorded_progress_local_mirror_v1';

  final Map<String, _PendingRecordedSession> _pending =
      <String, _PendingRecordedSession>{};
  final Map<String, Map<String, dynamic>> _mirror =
      <String, Map<String, dynamic>>{};

  bool _loaded = false;
  bool _flushing = false;
  bool _listening = false;

  Future<void> start() async {
    await ensureLoaded();
    if (!_listening) {
      _listening = true;
      AppConnectivity.instance.isOfflineListenable.addListener(() {
        if (!AppConnectivity.instance.isOffline) {
          unawaited(flushPending());
        }
      });
    }
    unawaited(flushPending());
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final value = entry.value;
            if (value is Map) {
              _pending[entry.key.toString()] = _PendingRecordedSession.fromJson(
                Map<String, dynamic>.from(value),
              );
            }
          }
        }
      } catch (_) {}
    }
    final rawMirror = prefs.getString(_mirrorPrefsKey);
    if (rawMirror != null && rawMirror.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawMirror);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final value = entry.value;
            if (value is Map) {
              _mirror[entry.key.toString()] = Map<String, dynamic>.from(value);
            }
          }
        }
      } catch (_) {}
    }
    _loaded = true;
  }

  String keyFor({
    required String uid,
    required String courseKey,
    required String sessionId,
  }) => '$uid|$courseKey|$sessionId';

  Future<Map<String, dynamic>> loadSessionProgress({
    required DatabaseReference progressRef,
    required String uid,
    required String courseKey,
    required String sessionId,
  }) async {
    await ensureLoaded();
    final key = keyFor(uid: uid, courseKey: courseKey, sessionId: sessionId);
    Map<String, dynamic> out = Map<String, dynamic>.from(
      _mirror[key] ?? const <String, dynamic>{},
    );
    if (!AppConnectivity.instance.isOffline) {
      try {
        final snap = await progressRef.get();
        if (snap.value is Map) {
          out = Map<String, dynamic>.from(snap.value as Map);
          await _updateMirror(key, out);
        }
      } catch (_) {}
    }
    final pending = _pending[key];
    if (pending != null) {
      out = _mergePatch(out, pending.patch);
      out['lessonNotes'] = _mergeNotes(out['lessonNotes'], pending.noteOps);
      await _updateMirror(key, out);
    }
    return out;
  }

  Future<Map<String, dynamic>> mergeWithLocalProgress({
    required String uid,
    required String courseKey,
    required String sessionId,
    required Map<String, dynamic> firebaseProgress,
  }) async {
    await ensureLoaded();
    final key = keyFor(uid: uid, courseKey: courseKey, sessionId: sessionId);
    var result = Map<String, dynamic>.from(firebaseProgress);
    final pending = _pending[key];
    if (pending != null) {
      result = _mergePatch(result, pending.patch);
      result['lessonNotes'] = _mergeNotes(result['lessonNotes'], pending.noteOps);
    }
    return result;
  }

  Future<void> updateProgress({
    required DatabaseReference progressRef,
    required String uid,
    required String courseKey,
    required String sessionId,
    required Map<String, dynamic> patch,
  }) async {
    await ensureLoaded();
    final localPatch = _normalizePatch(patch);
    final key = keyFor(uid: uid, courseKey: courseKey, sessionId: sessionId);
    await _updateMirror(
      key,
      _mergePatch(_mirror[key] ?? const <String, dynamic>{}, localPatch),
    );
    await _queuePatch(
      uid: uid,
      courseKey: courseKey,
      sessionId: sessionId,
      patch: localPatch,
    );
    if (AppConnectivity.instance.isOffline) return;
    await flushSession(
      progressRef: progressRef,
      uid: uid,
      courseKey: courseKey,
      sessionId: sessionId,
    );
  }

  Future<String> saveNote({
    required DatabaseReference progressRef,
    required String uid,
    required String courseKey,
    required String sessionId,
    required String? noteId,
    required Map<String, dynamic> note,
  }) async {
    await ensureLoaded();
    final id = (noteId ?? progressRef.child('lessonNotes').push().key ?? '')
        .trim();
    if (id.isEmpty) throw Exception('Could not create note id.');
    final op = _PendingNoteOp(id: id, deleted: false, data: note);
    final key = keyFor(uid: uid, courseKey: courseKey, sessionId: sessionId);
    final mirrored = Map<String, dynamic>.from(
      _mirror[key] ?? const <String, dynamic>{},
    );
    mirrored['lessonNotes'] = _mergeNotes(mirrored['lessonNotes'], {id: op});
    await _updateMirror(key, mirrored);
    await _queueNoteOp(
      uid: uid,
      courseKey: courseKey,
      sessionId: sessionId,
      op: op,
    );
    if (!AppConnectivity.instance.isOffline) {
      await flushSession(
        progressRef: progressRef,
        uid: uid,
        courseKey: courseKey,
        sessionId: sessionId,
      );
    }
    return id;
  }

  Future<void> deleteNote({
    required DatabaseReference progressRef,
    required String uid,
    required String courseKey,
    required String sessionId,
    required String noteId,
  }) async {
    await ensureLoaded();
    final key = keyFor(uid: uid, courseKey: courseKey, sessionId: sessionId);
    final op = _PendingNoteOp(id: noteId, deleted: true, data: const {});
    final mirrored = Map<String, dynamic>.from(
      _mirror[key] ?? const <String, dynamic>{},
    );
    mirrored['lessonNotes'] = _mergeNotes(mirrored['lessonNotes'], {
      noteId: op,
    });
    await _updateMirror(key, mirrored);
    await _queueNoteOp(
      uid: uid,
      courseKey: courseKey,
      sessionId: sessionId,
      op: op,
    );
    if (!AppConnectivity.instance.isOffline) {
      await flushSession(
        progressRef: progressRef,
        uid: uid,
        courseKey: courseKey,
        sessionId: sessionId,
      );
    }
  }

  Future<void> flushPending() async {
    await ensureLoaded();
    if (_flushing || AppConnectivity.instance.isOffline || _pending.isEmpty) {
      return;
    }
    _flushing = true;
    try {
      final entries = _pending.entries.toList(growable: false);
      for (final entry in entries) {
        final pending = entry.value;
        final ref = FirebaseDatabase.instance
            .ref('users')
            .child(pending.uid)
            .child('courses')
            .child(pending.courseKey)
            .child('recorded_progress')
            .child(pending.sessionId);
        await flushSession(
          progressRef: ref,
          uid: pending.uid,
          courseKey: pending.courseKey,
          sessionId: pending.sessionId,
        );
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> flushSession({
    required DatabaseReference progressRef,
    required String uid,
    required String courseKey,
    required String sessionId,
  }) async {
    await ensureLoaded();
    final key = keyFor(uid: uid, courseKey: courseKey, sessionId: sessionId);
    final pending = _pending[key];
    if (pending == null || AppConnectivity.instance.isOffline) return;

    try {
      final snap = await progressRef.get();
      final remote = snap.value is Map
          ? Map<String, dynamic>.from(snap.value as Map)
          : <String, dynamic>{};
      final patch = _firebasePatch(_mergePatch(remote, pending.patch));
      final mirrorPatch = _mergePatch(remote, pending.patch);
      mirrorPatch['lessonNotes'] = _mergeNotes(
        remote['lessonNotes'],
        pending.noteOps,
      );
      if (patch.isNotEmpty) {
        await progressRef.update(patch);
      }
      for (final op in pending.noteOps.values) {
        final noteRef = progressRef.child('lessonNotes').child(op.id);
        if (op.deleted) {
          await noteRef.remove();
        } else {
          await noteRef.set(op.data);
        }
      }
      await _updateMirror(key, mirrorPatch);
      _pending.remove(key);
      await _save();
    } catch (e) {
      if (kDebugMode) debugPrint('Recorded progress sync failed: $e');
    }
  }

  Future<void> _queuePatch({
    required String uid,
    required String courseKey,
    required String sessionId,
    required Map<String, dynamic> patch,
  }) async {
    final key = keyFor(uid: uid, courseKey: courseKey, sessionId: sessionId);
    final current =
        _pending[key] ??
        _PendingRecordedSession(
          uid: uid,
          courseKey: courseKey,
          sessionId: sessionId,
          patch: const {},
          noteOps: const {},
        );
    _pending[key] = current.copyWith(patch: _mergePatch(current.patch, patch));
    await _save();
  }

  Future<void> _queueNoteOp({
    required String uid,
    required String courseKey,
    required String sessionId,
    required _PendingNoteOp op,
  }) async {
    final key = keyFor(uid: uid, courseKey: courseKey, sessionId: sessionId);
    final current =
        _pending[key] ??
        _PendingRecordedSession(
          uid: uid,
          courseKey: courseKey,
          sessionId: sessionId,
          patch: const {},
          noteOps: const {},
        );
    final ops = Map<String, _PendingNoteOp>.from(current.noteOps);
    ops[op.id] = op;
    _pending[key] = current.copyWith(noteOps: ops);
    await _save();
  }

  Map<String, dynamic> _normalizePatch(Map<String, dynamic> patch) {
    final out = Map<String, dynamic>.from(patch);
    final now = DateTime.now().millisecondsSinceEpoch;
    out['updatedAtLocal'] = now;
    out['updatedAt'] = now;
    if (out.containsKey('lastOpenedAt')) out['lastOpenedAt'] = now;
    if (out.containsKey('videoCompletedAt')) out['videoCompletedAt'] = now;
    if (out['videoCompleted'] == true && !out.containsKey('videoCompletedAt')) {
      out['videoCompletedAt'] = now;
    }
    return out;
  }

  Map<String, dynamic> _firebasePatch(Map<String, dynamic> merged) {
    final out = Map<String, dynamic>.from(merged)..remove('lessonNotes');
    final nowServer = ServerValue.timestamp;
    if (out.containsKey('updatedAt')) out['updatedAt'] = nowServer;
    if (out.containsKey('lastOpenedAt')) out['lastOpenedAt'] = nowServer;
    return out;
  }

  Map<String, dynamic> _mergePatch(
    Map<String, dynamic> base,
    Map<String, dynamic> patch,
  ) {
    final out = Map<String, dynamic>.from(base);
    for (final entry in patch.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key == 'videoCompleted') {
        out[key] = _asBool(out[key]) || _asBool(value);
      } else if (key == 'videoPositionMs' || key == 'videoDurationMs') {
        out[key] = _maxInt(out[key], value);
      } else if (key == 'videoCompletedAt' ||
          key == 'materialsCompletedAt' ||
          key == 'updatedAt' ||
          key == 'updatedAtLocal' ||
          key == 'lastOpenedAt') {
        out[key] = _maxInt(out[key], value);
      } else if (key == 'completed') {
        out[key] = _asBool(out[key]) || _asBool(value);
      } else {
        out[key] = value;
      }
    }
    if (_asBool(out['videoCompleted'])) {
      final duration = _asInt(out['videoDurationMs']);
      if (duration > 0) out['videoPositionMs'] = duration;
    }
    return out;
  }

  Map<String, dynamic> _mergeNotes(
    dynamic rawNotes,
    Map<String, _PendingNoteOp> ops,
  ) {
    final out = <String, dynamic>{};
    if (rawNotes is Map) {
      for (final entry in rawNotes.entries) {
        if (entry.value is Map) {
          out[entry.key.toString()] = Map<String, dynamic>.from(
            entry.value as Map,
          );
        }
      }
    }
    for (final op in ops.values) {
      if (op.deleted) {
        out.remove(op.id);
      } else {
        out[op.id] = op.data;
      }
    }
    return out;
  }

  bool _asBool(dynamic value) {
    if (value is bool) return value;
    final s = (value ?? '').toString().trim().toLowerCase();
    return s == 'true' || s == '1';
  }

  int _maxInt(dynamic a, dynamic b) =>
      _asInt(a) > _asInt(b) ? _asInt(a) : _asInt(b);

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse((value ?? '').toString()) ?? 0;
  }

  Future<void> _updateMirror(String key, Map<String, dynamic> value) async {
    _mirror[key] = Map<String, dynamic>.from(value);
    await _saveMirror();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_pending.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }

  Future<void> _saveMirror() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mirrorPrefsKey, jsonEncode(_mirror));
  }
}

class _PendingRecordedSession {
  const _PendingRecordedSession({
    required this.uid,
    required this.courseKey,
    required this.sessionId,
    required this.patch,
    required this.noteOps,
  });

  final String uid;
  final String courseKey;
  final String sessionId;
  final Map<String, dynamic> patch;
  final Map<String, _PendingNoteOp> noteOps;

  _PendingRecordedSession copyWith({
    Map<String, dynamic>? patch,
    Map<String, _PendingNoteOp>? noteOps,
  }) {
    return _PendingRecordedSession(
      uid: uid,
      courseKey: courseKey,
      sessionId: sessionId,
      patch: patch ?? this.patch,
      noteOps: noteOps ?? this.noteOps,
    );
  }

  Map<String, dynamic> toJson() => {
    'uid': uid,
    'courseKey': courseKey,
    'sessionId': sessionId,
    'patch': patch,
    'noteOps': noteOps.map((key, value) => MapEntry(key, value.toJson())),
  };

  factory _PendingRecordedSession.fromJson(Map<String, dynamic> json) {
    final rawOps = json['noteOps'];
    final ops = <String, _PendingNoteOp>{};
    if (rawOps is Map) {
      for (final entry in rawOps.entries) {
        final value = entry.value;
        if (value is Map) {
          final op = _PendingNoteOp.fromJson(Map<String, dynamic>.from(value));
          ops[op.id] = op;
        }
      }
    }
    final rawPatch = json['patch'];
    return _PendingRecordedSession(
      uid: (json['uid'] ?? '').toString(),
      courseKey: (json['courseKey'] ?? '').toString(),
      sessionId: (json['sessionId'] ?? '').toString(),
      patch: rawPatch is Map ? Map<String, dynamic>.from(rawPatch) : const {},
      noteOps: ops,
    );
  }
}

class _PendingNoteOp {
  const _PendingNoteOp({
    required this.id,
    required this.deleted,
    required this.data,
  });

  final String id;
  final bool deleted;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => {'id': id, 'deleted': deleted, 'data': data};

  factory _PendingNoteOp.fromJson(Map<String, dynamic> json) {
    final rawData = json['data'];
    return _PendingNoteOp(
      id: (json['id'] ?? '').toString(),
      deleted: json['deleted'] == true,
      data: rawData is Map ? Map<String, dynamic>.from(rawData) : const {},
    );
  }
}
