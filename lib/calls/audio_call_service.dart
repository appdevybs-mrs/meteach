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

  // Notifiers so UI rebinds when streams arrive later
  final ValueNotifier<MediaStream?> localStreamVN = ValueNotifier(null);
  final ValueNotifier<MediaStream?> remoteStreamVN = ValueNotifier(null);
  // --- video request popup ---
  final ValueNotifier<String?> videoOnRequestFromUid = ValueNotifier<String?>(null);

  // store the peer uid for this call (so enableVideo can notify them)
  String? _peerUid;

  // camera
  MediaStream? _cameraStream;
  MediaStreamTrack? _videoTrack;
  RTCRtpSender? _videoSender;
  RTCRtpTransceiver? _videoTransceiver;

  DatabaseReference? _callRef;

  StreamSubscription<DatabaseEvent>? _callSub;
  StreamSubscription<DatabaseEvent>? _remoteCandidatesSub;

  // renegotiation
  StreamSubscription<DatabaseEvent>? _reofferSub;
  StreamSubscription<DatabaseEvent>? _reanswerSub;
  bool _handlingReoffer = false;

  // commands
  StreamSubscription<DatabaseEvent>? _cmdSub;

  // chat
  StreamSubscription<DatabaseEvent>? _chatSub;
  final ValueNotifier<List<AudioChatMessage>> chatMessages =
  ValueNotifier<List<AudioChatMessage>>([]);

  String? callId;
  bool get inCall => callId != null;

  /// True if call negotiated with video enabled (initially or later)
  bool withVideo = false;

  bool _remoteAnswerApplied = false;
  bool _starting = false;
  bool _ending = false;

  // values: idle | ringing | accepted | declined | ended
  final ValueNotifier<String> callState = ValueNotifier<String>('idle');

  String get _meUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  Map<String, dynamic> get _iceConfig => {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  void _setStateSafe(String s) {
    if (callState.value != s) callState.value = s;
  }

  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  // ---------- cleanup ----------

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
  }

  Future<void> _closePeer() async {
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;

    _videoTrack = null;
    _videoSender = null;
  }

  Future<void> _resetState() async {
    callId = null;
    _callRef = null;
    _peerUid = null;
    videoOnRequestFromUid.value = null;

    withVideo = false;
    _remoteAnswerApplied = false;

    chatMessages.value = [];

    _setStateSafe('idle');

    _ending = false;
  }

  Future<void> _ensureFreshState() async {
    if (_pc != null || _localStream != null || _callRef != null) {
      await hangUp(localOnly: true);
    }
  }

  // ---------- connection guards ----------
  void _wirePcConnectionGuards() {
    final pc = _pc;
    if (pc == null) return;

    Future<void> endNow() async {
      if (_ending) return;
      _ending = true;
      _setStateSafe('ended');
      await hangUp(localOnly: false);
    }

    pc.onConnectionState = (RTCPeerConnectionState state) async {
      if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        await endNow();
      }
    };

    pc.onIceConnectionState = (RTCIceConnectionState state) async {
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        await endNow();
      }
    };
  }

  // ---------- peer creation ----------
  Future<void> _createPeer({
    required bool isCaller,
    required DatabaseReference callRef,
    required bool enableVideo,
  }) async {
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

    // ✅ IMPORTANT FIX:
    // Always create a recv-only video transceiver so that when either side
    // enables camera later, the other side can receive it immediately.
    try {
      try {
        _videoTransceiver = await _pc!.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(
            // Key change: create a real video m-line that can later SEND or RECEIVE
            direction: TransceiverDirection.SendRecv,
          ),
        );

        // Keep a stable sender so enableVideo() can replaceTrack() reliably
        _videoSender = _videoTransceiver!.sender;

        // If we started the call with video already enabled, attach it now
        if (enableVideo && _videoTrack != null) {
          await _videoSender!.replaceTrack(_videoTrack);
        } else {
          // Start audio-only but keep the m-line; no camera track yet
          await _videoSender!.replaceTrack(null);
        }
      } catch (_) {
        // ignore if platform doesn't support transceivers well
      }

    } catch (_) {
      // ignore if not supported on platform
    }

    // ✅ Prefer onAddStream (most reliable on Android for flutter_webrtc)
    _pc!.onAddStream = (MediaStream stream) {
      debugPrint('✅ onAddStream: id=${stream.id} vids=${stream.getVideoTracks().length} auds=${stream.getAudioTracks().length}');
      _remoteStream = stream;
      remoteStreamVN.value = stream;
    };

// ✅ Keep onTrack too (some platforms only fire onTrack)
    _pc!.onTrack = (RTCTrackEvent event) async {
      debugPrint('✅ onTrack: kind=${event.track.kind} streams=${event.streams.length}');

      // If platform provides a stream, use it
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        remoteStreamVN.value = _remoteStream;
        return;
      }

      // If no stream is provided, DON'T try to create one (causes your "stream is null")
      // Just wait for onAddStream to deliver it.
    };


    for (final t in _localStream!.getTracks()) {
      // add audio always
      if (t.kind == 'audio') {
        await _pc!.addTrack(t, _localStream!);
      }

      // if call started with video, also add the video track
      if (enableVideo && t.kind == 'video') {
        await _pc!.addTrack(t, _localStream!);
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
      if (data is Map && data['offer'] is Map) return data;
      await Future<void>.delayed(pollEvery);
    }

    throw Exception('Offer not ready yet (timeout). Try again.');
  }

  // ---------- call logs helpers ----------
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

  // ---------- chat ----------
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

  // ---------- renegotiation ----------
  Future<void> _renegotiate() async {
    final ref = _callRef;
    final pc = _pc;
    final me = _meUid;
    if (ref == null || pc == null || me.isEmpty) return;
    if (callState.value != 'accepted') return;

    // Avoid renegotiation in unstable signaling
    if (pc.signalingState != RTCSignalingState.RTCSignalingStateStable) return;

    final offer = await pc.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    });

    await pc.setLocalDescription(offer);

    await ref.child('reoffer').set({
      'from': me,
      'type': offer.type,
      'sdp': offer.sdp,
      'ts': ServerValue.timestamp,
    });
  }

  void _listenRenegotiation() {
    final ref = _callRef;
    final pc = _pc;
    final me = _meUid;
    if (ref == null || pc == null || me.isEmpty) return;

    _reofferSub?.cancel();
    _reanswerSub?.cancel();

    _reofferSub = ref.child('reoffer').onValue.listen((event) async {
      final v = event.snapshot.value;
      if (v is! Map) return;

      final from = (v['from'] ?? '').toString();
      if (from.isEmpty || from == me) return;

      if (_handlingReoffer) return;
      _handlingReoffer = true;

      try {
        final sdp = (v['sdp'] ?? '').toString();
        final type = (v['type'] ?? 'offer').toString();

        if (pc.signalingState != RTCSignalingState.RTCSignalingStateStable) {
          return;
        }

        await pc.setRemoteDescription(RTCSessionDescription(sdp, type));

        final answer = await pc.createAnswer({
          'offerToReceiveAudio': 1,
          'offerToReceiveVideo': 1,
        });

        await pc.setLocalDescription(answer);

        await ref.child('reanswer').set({
          'from': me,
          'type': answer.type,
          'sdp': answer.sdp,
          'ts': ServerValue.timestamp,
        });
      } catch (_) {
        // ignore
      } finally {
        _handlingReoffer = false;
      }
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

  // ---------- commands ----------
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
        // if I'm already on camera, ignore (or you can auto-accept if you want)
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

  // ---------- video ----------
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

    // 1) Prefer transceiver sender if we created it
    if (_videoTransceiver != null) {
      _videoSender = _videoTransceiver!.sender;
      return;
    }

    // 2) Fallback: try to find a sender that already has a video track
    final senders = await pc.getSenders();
    for (final s in senders) {
      if (s.track?.kind == 'video') {
        _videoSender = s;
        return;
      }
    }

    // If we reach here: there is no video sender yet.
    // We'll create one later by adding a video track when camera is enabled.
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

    // Ensure there is a sender. If not, create one by adding the track.
    await _ensureVideoSender();

    if (_videoSender == null) {
      // No video sender exists yet -> addTrack creates it
      try {
        _videoSender = await _pc!.addTrack(_videoTrack!, _localStream!);
      } catch (_) {
        // If addTrack fails, fallback to replaceTrack path
      }
    } else {
      // Sender exists -> just replace the track
      await _replaceVideoTrack(_videoTrack);
    }

    withVideo = true;
    await _renegotiate();

    // Ask peer to enable too (your popup feature)
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

  // ---------- decline ----------
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

      final me = _meUid;
      if (me.isEmpty) throw Exception('Not logged in.');

      final id = _db.ref('calls').push().key!;
      callId = id;
      _callRef = _db.ref('calls/$id');
      _remoteAnswerApplied = false;

      this.withVideo = withVideo;

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

      await _cleanupSignalingSubsOnly();

      await _createPeer(
        isCaller: true,
        callRef: _callRef!,
        enableVideo: withVideo,
      );

      _listenRenegotiation();
      _listenCommandsAuto();
      _listenChat();

      final offer = await _pc!.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 1,
      });
      await _pc!.setLocalDescription(offer);

      await _callRef!.child('offer').set({
        'type': offer.type,
        'sdp': offer.sdp,
      });

      _callSub = _callRef!.onValue.listen((event) async {
        final v = event.snapshot.value;
        if (v is! Map) return;

        final status = (v['status'] ?? '').toString();

        if (status == 'declined') {
          _setStateSafe('declined');
          await hangUp(localOnly: true);
          return;
        }
        if (status == 'ended') {
          _setStateSafe('ended');
          await hangUp(localOnly: true);
          return;
        }

        final answer = v['answer'];
        final pc = _pc;

        if (status == 'accepted' && callState.value != 'accepted') {
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
      if (me.isEmpty) throw Exception('Not logged in.');

      this.callId = callId;
      _callRef = _db.ref('calls/$callId');
      _remoteAnswerApplied = true;

      final data = await _waitForOffer(callRef: _callRef!);

      final currentStatus = (data['status'] ?? '').toString();
      if (currentStatus == 'ended' || currentStatus == 'declined') {
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

      final videoFlag = (data['video'] ?? 0);
      withVideo =
      (videoFlag is int) ? videoFlag == 1 : videoFlag.toString() == '1';

      await _cleanupSignalingSubsOnly();

      await _createPeer(
        isCaller: false,
        callRef: _callRef!,
        enableVideo: withVideo,
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
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 1,
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
          _setStateSafe('declined');
          await hangUp(localOnly: true);
          return;
        }
        if (status == 'ended') {
          _setStateSafe('ended');
          await hangUp(localOnly: true);
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
    if (_ending) return;
    _ending = true;

    final ref = _callRef;
    final currentCallId = callId;

    _setStateSafe('ended');

    int? durationSec;
    String? callerUid;
    String? callerName;
    String? calleeUid;
    String? calleeName;

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
        }
      } catch (_) {}
    }

    // Notify peer before tearing down
    if (!localOnly && ref != null) {
      try {
        await ref.update({
          'status': 'ended',
          'endedAt': ServerValue.timestamp,
        });
      } catch (_) {}
    }

    await _cleanupAllSubs();
    await _disposeMedia();
    await _closePeer();

    // Update logs
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
        status: 'ended',
        video: withVideo,
        endedAt: DateTime.now().millisecondsSinceEpoch,
        durationSec: durationSec,
      );
    }

    await _resetState();
  }

  // ---------- audio controls ----------
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
