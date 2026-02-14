import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/foundation.dart';

import '../services/push_client.dart'; // <-- adjust path if different

class AudioCallService {
  AudioCallService._();
  static final I = AudioCallService._();

  final _db = FirebaseDatabase.instance;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  DatabaseReference? _callRef;
  StreamSubscription<DatabaseEvent>? _callSub;
  StreamSubscription<DatabaseEvent>? _remoteCandidatesSub;

  String? callId;
  bool get inCall => callId != null;

  bool _remoteSet = false;
  bool _starting = false;

  /// ✅ UI can listen to this (AudioCallScreen)
  /// values: idle | ringing | accepted | ended
  final ValueNotifier<String> callState = ValueNotifier<String>('idle');

  Map<String, dynamic> get _iceConfig => {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  // ---------- helpers ----------

  void _setStateSafe(String s) {
    if (callState.value != s) callState.value = s;
  }

  Future<void> _cleanupSubs() async {
    try {
      await _callSub?.cancel();
    } catch (_) {}
    try {
      await _remoteCandidatesSub?.cancel();
    } catch (_) {}

    _callSub = null;
    _remoteCandidatesSub = null;
  }

  Future<void> _disposeMedia() async {
    try {
      final tracks = _localStream?.getTracks() ?? const <MediaStreamTrack>[];
      for (final t in tracks) {
        try {
          t.enabled = false;
          await t.stop();
        } catch (_) {}
      }
    } catch (_) {}

    try {
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;

    try {
      await _remoteStream?.dispose();
    } catch (_) {}
    _remoteStream = null;
  }

  Future<void> _closePeer() async {
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
  }

  Future<void> _resetState() async {
    _remoteSet = false;
    callId = null;
    _callRef = null;
    _setStateSafe('idle');
  }

  Future<void> _ensureFreshState() async {
    if (_pc != null || _localStream != null || _callRef != null) {
      await hangUp(localOnly: true);
    }
  }

  void _wirePcConnectionGuards() {
    final pc = _pc;
    if (pc == null) return;

    pc.onConnectionState = (RTCPeerConnectionState state) async {
      // If the peer closes / disconnects, end locally + notify UI.
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _setStateSafe('ended');
        await hangUp(localOnly: true);
      }
    };

    pc.onIceConnectionState = (RTCIceConnectionState state) async {
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        _setStateSafe('ended');
        await hangUp(localOnly: true);
      }
    };
  }

  Future<void> _createPeer({
    required bool isCaller,
    required DatabaseReference callRef,
  }) async {
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });

    _pc = await createPeerConnection(_iceConfig);
    _wirePcConnectionGuards();

    // ✅ capture remote audio
    _pc!.onTrack = (RTCTrackEvent event) async {
      if (event.track.kind != 'audio') return;

      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        return;
      }

      _remoteStream ??= await createLocalMediaStream('remote');
      try {
        await _remoteStream!.addTrack(event.track);
      } catch (_) {}
    };

    for (final t in _localStream!.getAudioTracks()) {
      await _pc!.addTrack(t, _localStream!);
    }

    _pc!.onIceCandidate = (c) {
      if (c.candidate == null) return;
      final pc = _pc;
      if (pc == null) return;

      final node = isCaller ? 'callerCandidates' : 'calleeCandidates';
      callRef.child(node).push().set({
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };
  }

  Future<String?> _getUserFcmToken(String uid) async {
    final snap = await _db.ref('fcm_tokens/$uid/token').get();
    final token = (snap.value ?? '').toString().trim();
    return token.isEmpty ? null : token;
  }

  Future<void> _sendIncomingCallPush({
    required String calleeUid,
    required String callId,
    required String callerUid,
    required String callerName,
  }) async {
    final token = await _getUserFcmToken(calleeUid);
    if (token == null) return;

    await PushClient.sendToToken(
      token: token,
      title: 'Incoming call',
      message: '$callerName is calling you',
      data: {
        'type': 'incoming_call',
        'callId': callId,
        'peerUid': callerUid,
        'peerName': callerName,
      },
    );
  }

  Future<Map<dynamic, dynamic>> _waitForOffer({
    required DatabaseReference callRef,
    Duration timeout = const Duration(seconds: 12),
    Duration pollEvery = const Duration(milliseconds: 250),
  }) async {
    final end = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(end)) {
      final snap = await callRef.get();
      final data = snap.value;
      if (data is Map && data['offer'] is Map) {
        return data;
      }
      await Future<void>.delayed(pollEvery);
    }

    throw Exception('Offer not ready yet (timeout). Try again.');
  }

  // ---------- Call logs helpers ----------

  Future<String> _getDisplayName(String uid) async {
    try {
      final snap = await _db.ref('users/$uid').get();
      final v = snap.value;
      if (v is Map) {
        final first = (v['first_name'] ?? '').toString().trim();
        final last = (v['last_name'] ?? '').toString().trim();
        final full = ('$first $last').trim();
        if (full.isNotEmpty) return full;
      }
    } catch (_) {}
    return 'User';
  }

  Future<void> _writeCallLogForUser({
    required String uid,
    required String callId,
    required String peerUid,
    required String peerName,
    required String direction,
    required String status,
    int? createdAt,
    int? acceptedAt,
    int? endedAt,
    int? durationSec,
  }) async {
    final ref = _db.ref('call_logs/$uid/$callId');

    final data = <String, dynamic>{
      'callId': callId,
      'peerUid': peerUid,
      'peerName': peerName,
      'direction': direction,
      'status': status,
      'createdAt': createdAt ?? ServerValue.timestamp,
      'updatedAt': ServerValue.timestamp,
    };

    if (acceptedAt != null) data['acceptedAt'] = acceptedAt;
    if (endedAt != null) data['endedAt'] = endedAt;
    if (durationSec != null) data['durationSec'] = durationSec;

    try {
      await ref.update(data);
    } catch (_) {}
  }

  Future<void> _updateCallLogsForBoth({
    required String callId,
    required String callerUid,
    required String callerName,
    required String calleeUid,
    required String calleeName,
    required String status,
    int? acceptedAt,
    int? endedAt,
    int? durationSec,
  }) async {
    await _writeCallLogForUser(
      uid: callerUid,
      callId: callId,
      peerUid: calleeUid,
      peerName: calleeName,
      direction: 'outgoing',
      status: status,
      acceptedAt: acceptedAt,
      endedAt: endedAt,
      durationSec: durationSec,
    );

    await _writeCallLogForUser(
      uid: calleeUid,
      callId: callId,
      peerUid: callerUid,
      peerName: callerName,
      direction: 'incoming',
      status: status,
      acceptedAt: acceptedAt,
      endedAt: endedAt,
      durationSec: durationSec,
    );
  }

  // ---------- public API ----------

  Future<String> startCall({
    required String calleeUid,
    required String callerName,
  }) async {
    if (_starting) throw Exception('Call is already starting.');
    _starting = true;

    try {
      await _ensureFreshState();

      final me = FirebaseAuth.instance.currentUser?.uid;
      if (me == null) throw Exception('Not logged in.');

      final id = _db.ref('calls').push().key!;
      callId = id;
      _callRef = _db.ref('calls/$id');
      _remoteSet = false;

      final calleeName = await _getDisplayName(calleeUid);
      final cleanCallerName = callerName.trim().isEmpty ? 'Caller' : callerName.trim();

      await _callRef!.set({
        'callerUid': me,
        'callerName': cleanCallerName,
        'calleeUid': calleeUid,
        'calleeName': calleeName,
        'status': 'ringing',
        'createdAt': ServerValue.timestamp,
      });

      _setStateSafe('ringing');

      await _updateCallLogsForBoth(
        callId: id,
        callerUid: me,
        callerName: cleanCallerName,
        calleeUid: calleeUid,
        calleeName: calleeName,
        status: 'ringing',
      );

      try {
        await _sendIncomingCallPush(
          calleeUid: calleeUid,
          callId: id,
          callerUid: me,
          callerName: cleanCallerName,
        );
      } catch (_) {}

      await _createPeer(isCaller: true, callRef: _callRef!);

      final offer = await _pc!.createOffer({'offerToReceiveAudio': 1});
      await _pc!.setLocalDescription(offer);

      await _callRef!.child('offer').set({
        'type': offer.type,
        'sdp': offer.sdp,
      });

      await _cleanupSubs();
      _callSub = _callRef!.onValue.listen((event) async {
        final v = event.snapshot.value;
        if (v is! Map) return;

        final status = (v['status'] ?? '').toString();
        if (status == 'ended') {
          _setStateSafe('ended');
          await hangUp(localOnly: true);
          return;
        }

        final answer = v['answer'];
        if (answer is Map && !_remoteSet && _pc != null) {
          final sdp = (answer['sdp'] ?? '').toString();
          final type = (answer['type'] ?? 'answer').toString();
          await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
          _remoteSet = true;

          _setStateSafe('accepted');
        }
      });

      _remoteCandidatesSub =
          _callRef!.child('calleeCandidates').onChildAdded.listen((event) async {
            final v = event.snapshot.value;
            if (v is! Map) return;
            final pc = _pc;
            if (pc == null) return;

            final cand = RTCIceCandidate(
              (v['candidate'] ?? '').toString(),
              (v['sdpMid'] ?? '').toString(),
              (v['sdpMLineIndex'] is int)
                  ? v['sdpMLineIndex'] as int
                  : int.tryParse((v['sdpMLineIndex'] ?? '').toString()),
            );

            try {
              await pc.addCandidate(cand);
            } catch (_) {}
          });

      return id;
    } finally {
      _starting = false;
    }
  }

  Future<void> joinCall({required String callId}) async {
    if (_starting) throw Exception('Call is already starting.');
    _starting = true;

    try {
      await _ensureFreshState();

      final me = FirebaseAuth.instance.currentUser?.uid;
      if (me == null) throw Exception('Not logged in.');

      this.callId = callId;
      _callRef = _db.ref('calls/$callId');

      // callee sets remote immediately (offer)
      _remoteSet = true;

      final data = await _waitForOffer(callRef: _callRef!);
      final offer = data['offer'] as Map;

      final callerUid = (data['callerUid'] ?? '').toString();
      final callerName = (data['callerName'] ?? 'Caller').toString();
      final calleeUid = (data['calleeUid'] ?? me).toString();
      final calleeName = (data['calleeName'] ?? '').toString().trim().isEmpty
          ? await _getDisplayName(calleeUid)
          : (data['calleeName'] ?? '').toString();

      await _createPeer(isCaller: false, callRef: _callRef!);

      await _pc!.setRemoteDescription(
        RTCSessionDescription(
          (offer['sdp'] ?? '').toString(),
          (offer['type'] ?? 'offer').toString(),
        ),
      );

      final answer = await _pc!.createAnswer({'offerToReceiveAudio': 1});
      await _pc!.setLocalDescription(answer);

      await _callRef!.update({
        'answer': {'type': answer.type, 'sdp': answer.sdp},
        'status': 'accepted',
        'acceptedAt': ServerValue.timestamp,
      });

      _setStateSafe('accepted');

      await _updateCallLogsForBoth(
        callId: callId,
        callerUid: callerUid,
        callerName: callerName,
        calleeUid: calleeUid,
        calleeName: calleeName,
        status: 'accepted',
        acceptedAt: DateTime.now().millisecondsSinceEpoch,
      );

      await _cleanupSubs();

      _remoteCandidatesSub =
          _callRef!.child('callerCandidates').onChildAdded.listen((event) async {
            final v = event.snapshot.value;
            if (v is! Map) return;
            final pc = _pc;
            if (pc == null) return;

            final cand = RTCIceCandidate(
              (v['candidate'] ?? '').toString(),
              (v['sdpMid'] ?? '').toString(),
              (v['sdpMLineIndex'] is int)
                  ? v['sdpMLineIndex'] as int
                  : int.tryParse((v['sdpMLineIndex'] ?? '').toString()),
            );

            try {
              await pc.addCandidate(cand);
            } catch (_) {}
          });

      _callSub = _callRef!.onValue.listen((event) async {
        final v = event.snapshot.value;
        final status = (v is Map) ? (v['status'] ?? '').toString() : '';

        if (status == 'ended') {
          _setStateSafe('ended');
          await hangUp(localOnly: true);
        }
      });
    } finally {
      _starting = false;
    }
  }

  Future<void> hangUp({bool localOnly = false}) async {
    final ref = _callRef;
    final currentCallId = callId;

    // Always notify UI that call is ending (even localOnly)
    _setStateSafe('ended');

    int? durationSec;
    String? callerUid;
    String? callerName;
    String? calleeUid;
    String? calleeName;

    if (!localOnly && ref != null) {
      try {
        final snap = await ref.get();
        final v = snap.value;
        if (v is Map) {
          callerUid = (v['callerUid'] ?? '').toString();
          callerName = (v['callerName'] ?? 'Caller').toString();
          calleeUid = (v['calleeUid'] ?? '').toString();
          calleeName = (v['calleeName'] ?? '').toString();

          final acceptedAt = v['acceptedAt'];
          if (acceptedAt is int) {
            final now = DateTime.now().millisecondsSinceEpoch;
            durationSec = ((now - acceptedAt) / 1000).floor();
            if (durationSec < 0) durationSec = 0;
          }
        }
      } catch (_) {}
    }

    await _cleanupSubs();
    await _disposeMedia();
    await _closePeer();

    if (!localOnly && ref != null) {
      try {
        await ref.update({
          'status': 'ended',
          'endedAt': ServerValue.timestamp,
        });
      } catch (_) {}
    }

    if (!localOnly &&
        currentCallId != null &&
        callerUid != null &&
        callerUid!.isNotEmpty &&
        calleeUid != null &&
        calleeUid!.isNotEmpty) {
      await _updateCallLogsForBoth(
        callId: currentCallId,
        callerUid: callerUid!,
        callerName: callerName ?? 'Caller',
        calleeUid: calleeUid!,
        calleeName: (calleeName ?? '').trim().isEmpty
            ? await _getDisplayName(calleeUid!)
            : calleeName!,
        status: 'ended',
        endedAt: DateTime.now().millisecondsSinceEpoch,
        durationSec: durationSec,
      );
    }

    await _resetState();
  }

  void setMuted(bool muted) {
    final tracks = _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[];
    for (final t in tracks) {
      t.enabled = !muted;
    }
  }

  /// 🔊 Speaker toggle (used by AudioCallScreen)
  Future<void> setSpeakerOn(bool on) async {
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (_) {}
  }
}
