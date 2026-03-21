import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/push_client.dart';

class AudioChatMessage {
  AudioChatMessage({
    required this.text,
    required this.fromUid,
    required this.ts,
    required this.myUid,
  });

  final String text;
  final String fromUid;
  final int ts;
  final String myUid;

  bool get fromMe => fromUid == myUid;
}

class AudioCallService {
  AudioCallService._();
  static final I = AudioCallService._();

  final _db = FirebaseDatabase.instance;

  RTCPeerConnection? _pc;

  MediaStream? _localStream;
  MediaStream? _remoteStream;

  final ValueNotifier<MediaStream?> localStreamVN = ValueNotifier(null);
  final ValueNotifier<MediaStream?> remoteStreamVN = ValueNotifier(null);

  final ValueNotifier<String?> videoOnRequestFromUid = ValueNotifier<String?>(null);

  String? _peerUid;

  MediaStream? _cameraStream;
  MediaStreamTrack? _videoTrack;
  RTCRtpSender? _videoSender;
  RTCRtpTransceiver? _videoTransceiver;

  DatabaseReference? _callRef;

  StreamSubscription<DatabaseEvent>? _callSub;
  StreamSubscription<DatabaseEvent>? _remoteCandidatesSub;

  StreamSubscription<DatabaseEvent>? _reofferSub;
  StreamSubscription<DatabaseEvent>? _reanswerSub;
  bool _handlingReoffer = false;
  Map<dynamic, dynamic>? _pendingReoffer;

  StreamSubscription<DatabaseEvent>? _cmdSub;

  StreamSubscription<DatabaseEvent>? _chatSub;
  final ValueNotifier<List<AudioChatMessage>> chatMessages =
  ValueNotifier<List<AudioChatMessage>>([]);

  String? callId;
  bool get inCall => callId != null;

  bool withVideo = false;

  bool _remoteAnswerApplied = false;
  bool _starting = false;
  bool _ending = false;

  bool _isCaller = false;

  Timer? _ringTimeoutTimer;
  static const Duration _ringTimeout = Duration(seconds: 10);

  Timer? _disconnectGraceTimer;
  static const Duration _disconnectGrace = Duration(seconds: 8);

  Timer? _renegotiateRetryTimer;

  final ValueNotifier<String> callState = ValueNotifier<String>('idle');
  final ValueNotifier<bool> mediaConnected = ValueNotifier<bool>(false);

  String get _meUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  Map<String, dynamic> get _iceConfig => {
    'sdpSemantics': 'unified-plan',
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  void _setStateSafe(String s) {
    if (callState.value != s) {
      callState.value = s;
    }
  }

  void _setMediaConnected(bool v) {
    if (mediaConnected.value != v) {
      mediaConnected.value = v;
    }
  }

  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  DatabaseReference _presenceRefFor(String uid) => _db.ref('presence/in_call/$uid');

  Future<bool> _isUserBusy(String uid) async {
    try {
      final snap = await _presenceRefFor(uid).get();
      final v = snap.value;
      if (v == null) return false;

      if (v is bool) return v == true;
      if (v is int) return v == 1;

      if (v is String) {
        final s = v.trim().toLowerCase();
        if (s == '1' || s == 'true') return true;
        if (s == '0' || s == 'false') return false;
      }

      if (v is Map) {
        final active = v['active'];
        if (active is bool) return active == true;
        if (active is int) return active == 1;
        if (active != null) {
          final s = active.toString().trim().toLowerCase();
          return s == '1' || s == 'true';
        }
      }
    } catch (_) {}
    return false;
  }

  Future<void> _setMyInCallPresence({required String callId}) async {
    final me = _meUid;
    if (me.isEmpty) return;

    final ref = _presenceRefFor(me);

    try {
      await ref.onDisconnect().remove();
    } catch (_) {}

    try {
      await ref.set({
        'active': 1,
        'callId': callId,
        'ts': ServerValue.timestamp,
      });
    } catch (_) {}
  }

  Future<void> _clearMyInCallPresence() async {
    final me = _meUid;
    if (me.isEmpty) return;
    try {
      await _presenceRefFor(me).remove();
    } catch (_) {}
  }

  Future<void> _cleanupAllSubs() async {
    Future<void> cancel(StreamSubscription? s) async {
      try {
        await s?.cancel();
      } catch (_) {}
    }

    await cancel(_callSub);
    await cancel(_remoteCandidatesSub);
    await cancel(_reofferSub);
    await cancel(_reanswerSub);
    await cancel(_cmdSub);
    await cancel(_chatSub);

    _callSub = null;
    _remoteCandidatesSub = null;
    _reofferSub = null;
    _reanswerSub = null;
    _cmdSub = null;
    _chatSub = null;
  }

  Future<void> _cleanupSignalingSubsOnly() async {
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
      final tracks = _cameraStream?.getTracks() ?? const <MediaStreamTrack>[];
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
    localStreamVN.value = null;

    try {
      await _remoteStream?.dispose();
    } catch (_) {}
    _remoteStream = null;
    remoteStreamVN.value = null;

    try {
      await _cameraStream?.dispose();
    } catch (_) {}
    _cameraStream = null;

    _videoTrack = null;
    _videoSender = null;
    _videoTransceiver = null;
  }

  Future<void> _closePeer() async {
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;

    _videoTrack = null;
    _videoSender = null;
    _videoTransceiver = null;
  }

  Future<void> _resetState() async {
    callId = null;
    _callRef = null;
    _peerUid = null;
    videoOnRequestFromUid.value = null;

    withVideo = false;
    _remoteAnswerApplied = false;

    chatMessages.value = [];

    _pendingReoffer = null;
    _renegotiateRetryTimer?.cancel();
    _renegotiateRetryTimer = null;

    _setMediaConnected(false);
    _setStateSafe('idle');

    _ending = false;
  }

  Future<void> _ensureFreshState() async {
    if (_pc != null || _localStream != null || _callRef != null) {
      await hangUp(localOnly: true);
    }
  }

  void _cancelRingTimeout() {
    _ringTimeoutTimer?.cancel();
    _ringTimeoutTimer = null;
  }

  void _wirePcConnectionGuards() {
    final pc = _pc;
    if (pc == null) return;

    Future<void> endNow() async {
      if (_ending) return;
      await _endCall(reason: 'ended', localOnly: false);
    }

    pc.onConnectionState = (RTCPeerConnectionState state) async {
      debugPrint('📡 onConnectionState=$state');

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _cancelRingTimeout();
        _setMediaConnected(true);
        _setStateSafe('accepted');
        _disconnectGraceTimer?.cancel();
        _disconnectGraceTimer = null;
        return;
      }

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _setMediaConnected(false);
        await endNow();
        return;
      }

      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _setMediaConnected(false);
        _disconnectGraceTimer?.cancel();
        _disconnectGraceTimer = Timer(_disconnectGrace, () async {
          final nowState = _pc?.connectionState;
          debugPrint('⏳ disconnect grace done, connectionState=$nowState');
          if (nowState ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
            await endNow();
          }
        });
      } else {
        _disconnectGraceTimer?.cancel();
        _disconnectGraceTimer = null;
      }
    };

    pc.onIceConnectionState = (RTCIceConnectionState state) async {
      debugPrint('🧊 onIceConnectionState=$state');

      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _cancelRingTimeout();
        _setMediaConnected(true);
        _setStateSafe('accepted');
        _disconnectGraceTimer?.cancel();
        _disconnectGraceTimer = null;
        return;
      }

      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        _setMediaConnected(false);
        await endNow();
        return;
      }

      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _setMediaConnected(false);
        _disconnectGraceTimer?.cancel();
        _disconnectGraceTimer = Timer(_disconnectGrace, () async {
          final nowState = _pc?.iceConnectionState;
          debugPrint('⏳ disconnect grace done, iceConnectionState=$nowState');
          if (nowState ==
              RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
            await endNow();
          }
        });
      } else {
        _disconnectGraceTimer?.cancel();
        _disconnectGraceTimer = null;
      }
    };
  }

  Future<MediaStream> _ensureRemoteStream() async {
    if (_remoteStream != null) return _remoteStream!;
    final s = await createLocalMediaStream(
      'remote-${DateTime.now().millisecondsSinceEpoch}',
    );
    _remoteStream = s;
    remoteStreamVN.value = s;
    return s;
  }

  Future<void> _attachRemoteTrack(RTCTrackEvent event) async {
    final track = event.track;
    if (track == null) return;

    try {
      track.enabled = true;
    } catch (_) {}

    if (event.streams.isNotEmpty) {
      final s = event.streams.first;
      _remoteStream = s;

      if (!identical(remoteStreamVN.value, s)) {
        remoteStreamVN.value = s;
      } else {
        remoteStreamVN.value = null;
        remoteStreamVN.value = s;
      }
      return;
    }

    final rs = await _ensureRemoteStream();

    try {
      final already = rs.getTracks().any((t) => t.id == track.id);
      if (!already) {
        await rs.addTrack(track);
      }
    } catch (_) {}

    remoteStreamVN.value = null;
    remoteStreamVN.value = rs;
  }

  Future<void> _createPeer({
    required bool isCaller,
    required DatabaseReference callRef,
    required bool enableVideo,
  }) async {
    _isCaller = isCaller;

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

    localStreamVN.value = _localStream;

    final vids = _localStream!.getVideoTracks();
    _videoTrack = vids.isNotEmpty ? vids.first : null;
    _cameraStream = enableVideo ? _localStream : null;

    _pc = await createPeerConnection(_iceConfig);
    _wirePcConnectionGuards();

    _pc!.onAddStream = (MediaStream stream) {
      debugPrint(
        '✅ onAddStream: id=${stream.id} vids=${stream.getVideoTracks().length} auds=${stream.getAudioTracks().length}',
      );
      _remoteStream = stream;
      remoteStreamVN.value = stream;
    };

    _pc!.onTrack = (RTCTrackEvent event) async {
      debugPrint(
        '✅ onTrack: kind=${event.track.kind} streams=${event.streams.length}',
      );
      await _attachRemoteTrack(event);
    };

    for (final t in _localStream!.getTracks()) {
      final sender = await _pc!.addTrack(t, _localStream!);
      if (t.kind == 'video') {
        _videoSender = sender;
      }
    }

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
      if (data is Map && data['offer'] is Map) return data;
      await Future<void>.delayed(pollEvery);
    }

    throw Exception('Offer not ready yet (timeout). Try again.');
  }

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

  void _listenChat() {
    final ref = _callRef;
    final me = _meUid;
    if (ref == null || me.isEmpty) return;

    _chatSub?.cancel();
    chatMessages.value = [];

    _chatSub = ref.child('chat').limitToLast(120).onChildAdded.listen((event) {
      final v = event.snapshot.value;
      if (v is! Map) return;

      final from = (v['from'] ?? '').toString();
      final text = (v['text'] ?? '').toString();
      final tsVal = v['ts'];

      final ts = (tsVal is int)
          ? tsVal
          : int.tryParse(tsVal?.toString() ?? '') ??
          DateTime.now().millisecondsSinceEpoch;

      if (text.trim().isEmpty || from.isEmpty) return;

      final list = List<AudioChatMessage>.from(chatMessages.value);
      list.add(AudioChatMessage(
        text: text.trim(),
        fromUid: from,
        ts: ts,
        myUid: me,
      ));
      list.sort((a, b) => a.ts.compareTo(b.ts));
      chatMessages.value = list;
    });
  }

  Future<void> sendChatMessage(String text) async {
    final ref = _callRef;
    if (ref == null) return;
    final me = _meUid;
    if (me.isEmpty) return;

    final t = text.trim();
    if (t.isEmpty) return;

    await ref.child('chat').push().set({
      'from': me,
      'text': t,
      'ts': ServerValue.timestamp,
    });
  }

  Future<void> _renegotiate() async {
    final ref = _callRef;
    final pc = _pc;
    final me = _meUid;
    if (ref == null || pc == null || me.isEmpty) return;
    if (callState.value != 'accepted') return;

    if (pc.signalingState != RTCSignalingState.RTCSignalingStateStable) {
      _renegotiateRetryTimer?.cancel();
      _renegotiateRetryTimer = Timer(const Duration(milliseconds: 350), () {
        _renegotiate();
      });
      return;
    }

    final offer = await pc.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': true,
    });

    await pc.setLocalDescription(offer);

    await ref.child('reoffer').set({
      'from': me,
      'type': offer.type,
      'sdp': offer.sdp,
      'ts': ServerValue.timestamp,
    });
  }

  Future<void> _drainPendingReoffer() async {
    if (_handlingReoffer) return;

    final ref = _callRef;
    final pc = _pc;
    final me = _meUid;
    if (ref == null || pc == null || me.isEmpty) return;

    _handlingReoffer = true;
    try {
      while (_pendingReoffer != null) {
        final v = _pendingReoffer!;
        _pendingReoffer = null;

        final sdp = (v['sdp'] ?? '').toString();
        final type = (v['type'] ?? 'offer').toString();

        if (pc.signalingState != RTCSignalingState.RTCSignalingStateStable) {
          if (!_isCaller &&
              pc.signalingState ==
                  RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
            try {
              await pc.setLocalDescription(
                RTCSessionDescription('', 'rollback'),
              );
            } catch (_) {}
          }

          _pendingReoffer = v;
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }

        await pc.setRemoteDescription(RTCSessionDescription(sdp, type));

        final answer = await pc.createAnswer({
          'offerToReceiveAudio': true,
          'offerToReceiveVideo': true,
        });

        await pc.setLocalDescription(answer);

        await ref.child('reanswer').set({
          'from': me,
          'type': answer.type,
          'sdp': answer.sdp,
          'ts': ServerValue.timestamp,
        });
      }
    } catch (_) {
    } finally {
      _handlingReoffer = false;
    }
  }

  void _listenRenegotiation() {
    final ref = _callRef;
    final pc = _pc;
    final me = _meUid;
    if (ref == null || pc == null || me.isEmpty) return;

    _reofferSub?.cancel();
    _reanswerSub?.cancel();

    _reofferSub = ref.child('reoffer').onValue.listen((event) {
      final v = event.snapshot.value;
      if (v is! Map) return;

      final from = (v['from'] ?? '').toString();
      if (from.isEmpty || from == me) return;

      _pendingReoffer = v;
      _drainPendingReoffer();
    });

    _reanswerSub = ref.child('reanswer').onValue.listen((event) async {
      final v = event.snapshot.value;
      if (v is! Map) return;

      final from = (v['from'] ?? '').toString();
      if (from.isEmpty || from == me) return;

      try {
        if (pc.signalingState !=
            RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          return;
        }

        final sdp = (v['sdp'] ?? '').toString();
        final type = (v['type'] ?? 'answer').toString();
        await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
      } catch (_) {}
    });
  }

  void _listenCommandsAuto() {
    final ref = _callRef;
    final me = _meUid;
    if (ref == null || me.isEmpty) return;

    _cmdSub?.cancel();
    _cmdSub = ref.child('commands').onChildAdded.listen((event) async {
      final v = event.snapshot.value;
      if (v is! Map) return;

      final target = (v['target'] ?? '').toString();
      final action = (v['action'] ?? '').toString();
      debugPrint('CMD RECEIVED: $v');

      if (target != me) return;

      if (action == 'camera_off') {
        await disableVideo();
        return;
      }

      if (action == 'camera_on_request') {
        if (withVideo) return;

        final from = (v['from'] ?? '').toString();
        videoOnRequestFromUid.value = from.isNotEmpty ? from : 'peer';
        return;
      }
    });
  }

  Future<void> requestPeerCameraOn(String peerUid) async {
    final ref = _callRef;
    if (ref == null) return;

    await ref.child('commands').push().set({
      'action': 'camera_on_request',
      'target': peerUid,
      'from': _meUid,
      'ts': ServerValue.timestamp,
    });
  }

  void clearVideoOnRequest() {
    videoOnRequestFromUid.value = null;
  }

  Future<void> requestPeerCameraOff(String peerUid) async {
    final ref = _callRef;
    if (ref == null) return;

    await ref.child('commands').push().set({
      'action': 'camera_off',
      'target': peerUid,
      'ts': ServerValue.timestamp,
    });
  }

  Future<void> _startVideoTrack() async {
    if (_localStream == null) return;
    if (_videoTrack != null) return;

    final camStream = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        'facingMode': 'user',
        'width': {'ideal': 640},
        'height': {'ideal': 480},
        'frameRate': {'ideal': 24},
      },
    });

    final tracks = camStream.getVideoTracks();
    if (tracks.isEmpty) {
      try {
        await camStream.dispose();
      } catch (_) {}
      return;
    }

    _cameraStream = camStream;
    _videoTrack = tracks.first;

    try {
      await _localStream!.addTrack(_videoTrack!);
    } catch (_) {}
  }

  Future<void> _stopVideoTrack() async {
    final t = _videoTrack;
    _videoTrack = null;

    if (t != null) {
      try {
        await _localStream?.removeTrack(t);
      } catch (_) {}
      try {
        t.enabled = false;
        await t.stop();
      } catch (_) {}
    }

    try {
      final tracks = _cameraStream?.getTracks() ?? const <MediaStreamTrack>[];
      for (final tr in tracks) {
        try {
          tr.enabled = false;
          await tr.stop();
        } catch (_) {}
      }
    } catch (_) {}

    try {
      await _cameraStream?.dispose();
    } catch (_) {}
    _cameraStream = null;
  }

  Future<void> _ensureVideoSender() async {
    if (_videoSender != null) return;

    final pc = _pc;
    if (pc == null) return;

    if (_videoTransceiver != null) {
      _videoSender = _videoTransceiver!.sender;
      return;
    }

    try {
      final dynPc = pc as dynamic;
      final List<dynamic> transceivers = await dynPc.getTransceivers();

      for (final dynTr in transceivers) {
        try {
          final RTCRtpTransceiver? tr =
          (dynTr is RTCRtpTransceiver) ? dynTr : (dynTr as RTCRtpTransceiver?);

          if (tr == null) continue;

          final receiver = tr.receiver;
          final rTrack = receiver.track;

          if (rTrack != null && rTrack.kind == 'video') {
            _videoTransceiver = tr;
            _videoSender = tr.sender;
            return;
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _replaceVideoTrack(MediaStreamTrack? newTrack) async {
    final pc = _pc;
    if (pc == null) return;

    await _ensureVideoSender();

    if (_videoSender != null) {
      try {
        await _videoSender!.replaceTrack(newTrack);
      } catch (_) {}
    }
  }

  Future<void> enableVideo() async {
    if (_pc == null || _localStream == null) return;

    await _startVideoTrack();
    if (_videoTrack == null) {
      throw Exception('Camera track not available.');
    }

    await _ensureVideoSender();

    if (_videoSender == null) {
      try {
        _videoSender = await _pc!.addTrack(_videoTrack!, _localStream!);
      } catch (_) {}
    } else {
      await _replaceVideoTrack(_videoTrack);
    }

    withVideo = true;
    await _renegotiate();

    final peer = _peerUid;
    if (peer != null && peer.isNotEmpty) {
      await requestPeerCameraOn(peer);
    }
  }

  Future<void> disableVideo() async {
    if (_pc == null || _localStream == null) return;

    await _replaceVideoTrack(null);
    await _stopVideoTrack();

    withVideo = false;
    await _renegotiate();
  }

  Future<void> declineCall(String callId) async {
    final ref = _db.ref('calls/$callId');
    try {
      await ref.update({
        'status': 'declined',
        'endedAt': ServerValue.timestamp,
      });
    } catch (_) {}
    _setStateSafe('declined');
  }

  Future<void> _endCall({required String reason, required bool localOnly}) async {
    if (_ending) return;
    _ending = true;

    _cancelRingTimeout();
    _disconnectGraceTimer?.cancel();
    _disconnectGraceTimer = null;

    _renegotiateRetryTimer?.cancel();
    _renegotiateRetryTimer = null;

    final ref = _callRef;
    final currentCallId = callId;

    _setMediaConnected(false);
    _setStateSafe(reason);

    int? durationSec;
    String? callerUid;
    String? callerName;
    String? calleeUid;
    String? calleeName;
    bool videoFlag = withVideo;

    if (ref != null) {
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

          final vf = v['video'];
          if (vf is int) videoFlag = vf == 1;
          if (vf != null && vf.toString() == '1') videoFlag = true;
        }
      } catch (_) {}
    }

    if (!localOnly && ref != null) {
      try {
        await ref.update({
          'status': reason,
          'endedAt': ServerValue.timestamp,
        });
      } catch (_) {}
    }

    await _cleanupAllSubs();
    await _disposeMedia();
    await _closePeer();

    await _clearMyInCallPresence();

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
        calleeName: (calleeName ?? '').trim().isNotEmpty
            ? calleeName!
            : await _getDisplayName(calleeUid!),
        status: reason,
        video: videoFlag,
        endedAt: DateTime.now().millisecondsSinceEpoch,
        durationSec: durationSec,
      );
    }

    await _resetState();
  }

  Future<String> startCall({
    required String calleeUid,
    required String callerName,
    bool withVideo = false,
  }) async {
    if (_starting) throw Exception('Call is already starting.');
    _starting = true;

    try {
      await _ensureFreshState();

      final me = _meUid;
      if (me.isEmpty) throw Exception('You must be logged in to place a call.');

      final calleeToken = await _getUserFcmToken(calleeUid);
      if (calleeToken == null) {
        throw Exception('User is currently logged out and unavailable.');
      }

      final busy = await _isUserBusy(calleeUid);
      if (busy) {
        _setStateSafe('busy');
        throw Exception('User is busy right now.');
      }

      final id = _db.ref('calls').push().key!;
      callId = id;
      _callRef = _db.ref('calls/$id');
      _remoteAnswerApplied = false;

      this.withVideo = false;

      final calleeName = await _getDisplayName(calleeUid);
      final cleanCallerName =
      callerName.trim().isEmpty ? 'Caller' : callerName.trim();
      _peerUid = calleeUid;

      await _callRef!.set({
        'callerUid': me,
        'callerName': cleanCallerName,
        'calleeUid': calleeUid,
        'calleeName': calleeName,
        'status': 'ringing',
        'video': 0,
        'createdAt': ServerValue.timestamp,
      });

      await _setMyInCallPresence(callId: id);

      _setStateSafe('ringing');

      await _updateCallLogsForBoth(
        callId: id,
        callerUid: me,
        callerName: cleanCallerName,
        calleeUid: calleeUid,
        calleeName: calleeName,
        status: 'ringing',
        video: false,
      );

      try {
        await _sendIncomingCallPush(
          calleeUid: calleeUid,
          callId: id,
          callerUid: me,
          callerName: cleanCallerName,
          video: false,
        );
      } catch (_) {}

      await _cleanupSignalingSubsOnly();

      await _createPeer(
        isCaller: true,
        callRef: _callRef!,
        enableVideo: false,
      );

      _listenRenegotiation();
      _listenCommandsAuto();
      _listenChat();

      final offer = await _pc!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });
      await _pc!.setLocalDescription(offer);

      await _callRef!.child('offer').set({
        'type': offer.type,
        'sdp': offer.sdp,
      });

      _cancelRingTimeout();
      _ringTimeoutTimer = Timer(_ringTimeout, () async {
        try {
          final current = callId;
          final refNow = _callRef;
          if (current == null || refNow == null) return;

          final snap = await refNow.get();
          final v = snap.value;
          if (v is Map) {
            final status = (v['status'] ?? '').toString();
            if (status == 'ringing') {
              await _endCall(reason: 'no_answer', localOnly: false);
            }
          }
        } catch (_) {}
      });

      _callSub = _callRef!.onValue.listen((event) async {
        final v = event.snapshot.value;
        if (v is! Map) return;

        final status = (v['status'] ?? '').toString();

        if (status == 'declined') {
          _cancelRingTimeout();
          await _endCall(reason: 'declined', localOnly: true);
          return;
        }

        if (status == 'busy') {
          _cancelRingTimeout();
          await _endCall(reason: 'busy', localOnly: true);
          return;
        }

        if (status == 'no_answer') {
          _cancelRingTimeout();
          await _endCall(reason: 'no_answer', localOnly: true);
          return;
        }

        if (status == 'ended') {
          _cancelRingTimeout();
          await _endCall(reason: 'ended', localOnly: true);
          return;
        }

        final answer = v['answer'];
        final pc = _pc;

        if (status == 'accepted' && callState.value != 'accepted') {
          _cancelRingTimeout();
          _setStateSafe('accepted');
        }

        if (answer is Map && !_remoteAnswerApplied && pc != null) {
          if (pc.signalingState !=
              RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
            return;
          }

          _remoteAnswerApplied = true;

          final sdp = (answer['sdp'] ?? '').toString();
          final type = (answer['type'] ?? 'answer').toString();

          try {
            await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
            _setStateSafe('accepted');
          } catch (_) {}
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

      final me = _meUid;
      if (me.isEmpty) throw Exception('You must be logged in to answer a call.');

      final iAmBusy = await _isUserBusy(me);
      if (iAmBusy) {
        try {
          await _db.ref('calls/$callId').update({
            'status': 'busy',
            'endedAt': ServerValue.timestamp,
          });
        } catch (_) {}
        _setStateSafe('busy');
        return;
      }

      this.callId = callId;
      _callRef = _db.ref('calls/$callId');
      _remoteAnswerApplied = true;

      final data = await _waitForOffer(callRef: _callRef!);

      final currentStatus = (data['status'] ?? '').toString();
      if (currentStatus == 'ended' ||
          currentStatus == 'declined' ||
          currentStatus == 'busy' ||
          currentStatus == 'no_answer') {
        _setStateSafe(currentStatus);
        await hangUp(localOnly: true);
        return;
      }

      final offer = data['offer'] as Map;

      final callerUid = (data['callerUid'] ?? '').toString();
      _peerUid = callerUid;

      final callerName = (data['callerName'] ?? 'Caller').toString();
      final calleeUid = (data['calleeUid'] ?? me).toString();
      final calleeName = (data['calleeName'] ?? '').toString().trim().isEmpty
          ? await _getDisplayName(calleeUid)
          : (data['calleeName'] ?? '').toString();

      withVideo = false;

      await _cleanupSignalingSubsOnly();

      await _createPeer(
        isCaller: false,
        callRef: _callRef!,
        enableVideo: false,
      );

      _listenRenegotiation();
      _listenCommandsAuto();
      _listenChat();

      await _pc!.setRemoteDescription(
        RTCSessionDescription(
          (offer['sdp'] ?? '').toString(),
          (offer['type'] ?? 'offer').toString(),
        ),
      );

      final answer = await _pc!.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });
      await _pc!.setLocalDescription(answer);

      await _callRef!.update({
        'answer': {'type': answer.type, 'sdp': answer.sdp},
        'status': 'accepted',
        'acceptedAt': ServerValue.timestamp,
      });

      await _setMyInCallPresence(callId: callId);

      _setStateSafe('accepted');

      await _updateCallLogsForBoth(
        callId: callId,
        callerUid: callerUid,
        callerName: callerName,
        calleeUid: calleeUid,
        calleeName: calleeName,
        status: 'accepted',
        video: false,
        acceptedAt: DateTime.now().millisecondsSinceEpoch,
      );

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
        if (v is! Map) return;

        final status = (v['status'] ?? '').toString();

        if (status == 'declined') {
          await _endCall(reason: 'declined', localOnly: true);
          return;
        }
        if (status == 'busy') {
          await _endCall(reason: 'busy', localOnly: true);
          return;
        }
        if (status == 'no_answer') {
          await _endCall(reason: 'no_answer', localOnly: true);
          return;
        }
        if (status == 'ended') {
          await _endCall(reason: 'ended', localOnly: true);
          return;
        }
        if (status == 'accepted' && callState.value != 'accepted') {
          _setStateSafe('accepted');
        }
      });
    } finally {
      _starting = false;
    }
  }

  Future<void> hangUp({bool localOnly = false}) async {
    await _endCall(reason: 'ended', localOnly: localOnly);
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

  Future<void> switchCamera() async {
    try {
      final tracks = _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
      if (tracks.isEmpty) return;
      await Helper.switchCamera(tracks.first);
    } catch (_) {}
  }
}