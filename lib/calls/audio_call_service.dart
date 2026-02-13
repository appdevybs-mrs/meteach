import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/push_client.dart'; // <-- adjust path if different

class AudioCallService {
  AudioCallService._();
  static final I = AudioCallService._();

  final _db = FirebaseDatabase.instance;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  DatabaseReference? _callRef;
  StreamSubscription<DatabaseEvent>? _callSub;
  StreamSubscription<DatabaseEvent>? _remoteCandidatesSub;

  String? callId;
  bool get inCall => callId != null;

  bool _remoteSet = false;
  bool _starting = false;

  Map<String, dynamic> get _iceConfig => {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  // ---------- helpers ----------

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
  }

  Future<void> _ensureFreshState() async {
    if (_pc != null || _localStream != null || _callRef != null) {
      await hangUp(localOnly: true);
    }
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
    // your FCMService saves to /fcm_tokens/{uid}/token
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

      await _callRef!.set({
        'callerUid': me,
        'callerName': callerName,
        'calleeUid': calleeUid,
        'status': 'ringing',
        'createdAt': ServerValue.timestamp,
      });

      // best-effort push
      try {
        await _sendIncomingCallPush(
          calleeUid: calleeUid,
          callId: id,
          callerUid: me,
          callerName: callerName.trim().isEmpty ? 'Caller' : callerName.trim(),
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
          await hangUp(localOnly: true);
          return;
        }

        final answer = v['answer'];
        if (answer is Map && !_remoteSet && _pc != null) {
          final sdp = (answer['sdp'] ?? '').toString();
          final type = (answer['type'] ?? 'answer').toString();
          await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
          _remoteSet = true;
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
      });

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
        if (v is Map && (v['status'] ?? '').toString() == 'ended') {
          await hangUp(localOnly: true);
        }
      });
    } finally {
      _starting = false;
    }
  }

  Future<void> hangUp({bool localOnly = false}) async {
    final ref = _callRef;

    await _cleanupSubs();
    await _disposeMedia();
    await _closePeer();

    if (!localOnly && ref != null) {
      try {
        await ref.update({'status': 'ended'});
      } catch (_) {}
    }

    await _resetState();
  }

  void setMuted(bool muted) {
    final tracks = _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[];
    for (final t in tracks) {
      t.enabled = !muted;
    }
  }
}
