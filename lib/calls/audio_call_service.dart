import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/push_client.dart'; // keep your path as-is

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

  // ✅ NEW: video flag for current call
  bool withVideo = false;

  // ✅ UI can listen to this (AudioCallScreen)
  // values: idle | ringing | accepted | ended
  final ValueNotifier<String> callState = ValueNotifier<String>('idle');

  // ✅ NEW: captions (manual text captions)
  final ValueNotifier<String> remoteCaption = ValueNotifier<String>('');
  final ValueNotifier<String> localCaption = ValueNotifier<String>('');

  Map<String, dynamic> get _iceConfig => {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  void _setStateSafe(String s) {
    if (callState.value != s) callState.value = s;
  }

  // Expose streams for video renderers
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  // ---------- cleanup helpers ----------

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

    // reset call-scoped values
    withVideo = false;
    remoteCaption.value = '';
    localCaption.value = '';
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
      if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
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
    required bool enableVideo,
  }) async {
    // capture media
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': enableVideo
          ? {
        'facingMode': 'user',
        'width': {'ideal': 640},
        'height': {'ideal': 480},
        'frameRate': {'ideal': 24},
      }
          : false,
    });

    _pc = await createPeerConnection(_iceConfig);
    _wirePcConnectionGuards();

    _pc!.onTrack = (RTCTrackEvent event) async {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        return;
      }

      _remoteStream ??= await createLocalMediaStream('remote');
      try {
        await _remoteStream!.addTrack(event.track);
      } catch (_) {}
    };

    // add all tracks
    for (final t in _localStream!.getTracks()) {
      await _pc!.addTrack(t, _localStream!);
    }

    // ICE candidates
    _pc!.onIceCandidate = (c) {
      if (c.candidate == null) return;
      final node = isCaller ? 'callerCandidates' : 'calleeCandidates';
      callRef.child(node).push().set({
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };
  }

  // ---------- push helpers ----------

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
    required bool video,
  }) async {
    final token = await _getUserFcmToken(calleeUid);
    if (token == null) return;

    await PushClient.sendToToken(
      token: token,
      title: video ? 'Incoming video call' : 'Incoming call',
      message: '$callerName is calling you',
      data: {
        'type': 'incoming_call',
        'callId': callId,
        'peerUid': callerUid,
        'peerName': callerName,
        'video': video ? '1' : '0',
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

  // ---------- Call logs (keep your same logic) ----------

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
    required bool video,
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
      'video': video ? 1 : 0,
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
    required bool video,
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
      video: video,
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
      video: video,
      acceptedAt: acceptedAt,
      endedAt: endedAt,
      durationSec: durationSec,
    );
  }

  // ---------- captions ----------

  Future<void> sendCaption(String text) async {
    final ref = _callRef;
    if (ref == null) return;

    final me = FirebaseAuth.instance.currentUser?.uid;
    if (me == null) return;

    final t = text.trim();
    if (t.isEmpty) return;

    localCaption.value = t;

    // store in call node; other side listens and shows it
    await ref.child('captions').child(me).set({
      'text': t,
      'ts': ServerValue.timestamp,
    });
  }

  void _listenCaptions() {
    final ref = _callRef;
    if (ref == null) return;

    final me = FirebaseAuth.instance.currentUser?.uid;
    if (me == null) return;

    ref.child('captions').onValue.listen((event) {
      final v = event.snapshot.value;
      if (v is! Map) return;

      // pick caption from "the other user"
      String? otherText;

      v.forEach((k, vv) {
        if (k.toString() == me) return;
        if (vv is Map) {
          final t = (vv['text'] ?? '').toString();
          if (t.trim().isNotEmpty) otherText = t.trim();
        }
      });

      if (otherText != null) {
        remoteCaption.value = otherText!;
      }
    });
  }

  // ---------- public API ----------

  Future<String> startCall({
    required String calleeUid,
    required String callerName,
    bool withVideo = false,
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

      this.withVideo = withVideo;

      final calleeName = await _getDisplayName(calleeUid);
      final cleanCallerName =
      callerName.trim().isEmpty ? 'Caller' : callerName.trim();

      await _callRef!.set({
        'callerUid': me,
        'callerName': cleanCallerName,
        'calleeUid': calleeUid,
        'calleeName': calleeName,
        'status': 'ringing',
        'video': withVideo ? 1 : 0,
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
        video: withVideo,
      );

      try {
        await _sendIncomingCallPush(
          calleeUid: calleeUid,
          callId: id,
          callerUid: me,
          callerName: cleanCallerName,
          video: withVideo,
        );
      } catch (_) {}

      await _createPeer(isCaller: true, callRef: _callRef!, enableVideo: withVideo);

      final offer = await _pc!.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': withVideo ? 1 : 0,
      });
      await _pc!.setLocalDescription(offer);

      await _callRef!.child('offer').set({
        'type': offer.type,
        'sdp': offer.sdp,
      });

      _listenCaptions();

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

      _remoteSet = true;

      final data = await _waitForOffer(callRef: _callRef!);
      final offer = data['offer'] as Map;

      final callerUid = (data['callerUid'] ?? '').toString();
      final callerName = (data['callerName'] ?? 'Caller').toString();
      final calleeUid = (data['calleeUid'] ?? me).toString();
      final calleeName = (data['calleeName'] ?? '').toString().trim().isEmpty
          ? await _getDisplayName(calleeUid)
          : (data['calleeName'] ?? '').toString();

      final videoFlag = (data['video'] ?? 0);
      withVideo = (videoFlag is int)
          ? videoFlag == 1
          : videoFlag.toString() == '1';

      await _createPeer(
        isCaller: false,
        callRef: _callRef!,
        enableVideo: withVideo,
      );

      await _pc!.setRemoteDescription(
        RTCSessionDescription(
          (offer['sdp'] ?? '').toString(),
          (offer['type'] ?? 'offer').toString(),
        ),
      );

      final answer = await _pc!.createAnswer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': withVideo ? 1 : 0,
      });
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
        video: withVideo,
        acceptedAt: DateTime.now().millisecondsSinceEpoch,
      );

      _listenCaptions();

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
        video: withVideo,
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

  Future<void> setSpeakerOn(bool on) async {
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (_) {}
  }

  // ✅ NEW: camera enable/disable (video track)
  void setCameraEnabled(bool enabled) {
    final tracks = _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
    for (final t in tracks) {
      t.enabled = enabled;
    }
  }

  // ✅ NEW: switch camera
  Future<void> switchCamera() async {
    try {
      final tracks = _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
      if (tracks.isEmpty) return;
      await Helper.switchCamera(tracks.first);
    } catch (_) {}
  }
}
