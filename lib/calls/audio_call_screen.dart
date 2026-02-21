import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'audio_call_service.dart';

class AudioCallScreen extends StatefulWidget {
  const AudioCallScreen({
    super.key,
    required this.peerUid,
    required this.peerName,
    required this.isCaller,
    this.incomingCallId,
    this.callerName,
    this.startWithVideo = false,
  });

  final String peerUid;
  final String peerName;
  final bool isCaller;

  final String? incomingCallId;
  final String? callerName;

  final bool startWithVideo;

  @override
  State<AudioCallScreen> createState() => _AudioCallScreenState();
}

class _AudioCallScreenState extends State<AudioCallScreen> {
  bool _muted = false;
  bool _speakerOn = false;
  bool _cameraOn = false;

  bool _started = false;
  bool _callReady = false;
  bool _incomingWaiting = false;

  String _status = 'Starting…';

  Timer? _timer;
  int _seconds = 0;

  // ✅ caller auto-timeout (10s)
  Timer? _ringTimeout;

  late final RTCVideoRenderer _localRenderer;
  late final RTCVideoRenderer _remoteRenderer;
  bool _renderersInit = false;

  final _msgCtrl = TextEditingController();
  final _chatScroll = ScrollController();

  bool _didPop = false;

  // ✅ presence busy flag
  static const String _presenceInCallPath = 'presence/in_call';

  @override
  void initState() {
    super.initState();

    _localRenderer = RTCVideoRenderer();
    _remoteRenderer = RTCVideoRenderer();

    AudioCallService.I.callState.addListener(_onCallState);
    AudioCallService.I.localStreamVN.addListener(_bindStreams);
    AudioCallService.I.remoteStreamVN.addListener(_bindStreams);
    AudioCallService.I.chatMessages.addListener(_onChatChanged);
    AudioCallService.I.videoOnRequestFromUid.addListener(_onVideoRequest);

    _startOnce();
  }

  Future<void> _setInCallPresence(bool v) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseDatabase.instance.ref('$_presenceInCallPath/$uid').set(v);
    } catch (_) {}
  }

  Future<void> _ensureRenderersInit() async {
    if (_renderersInit) return;
    _renderersInit = true;
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  Future<void> _bindStreams() async {
    if (!mounted) return;
    await _ensureRenderersInit();

    final local = AudioCallService.I.localStreamVN.value;
    final remote = AudioCallService.I.remoteStreamVN.value;

    if (_localRenderer.srcObject != local) {
      _localRenderer.srcObject = local;
    }
    if (_remoteRenderer.srcObject != remote) {
      _remoteRenderer.srcObject = remote;
    }

    if (mounted) setState(() {});
  }

  void _onChatChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.animateTo(
          _chatScroll.position.maxScrollExtent + 120,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showPrettySnack(
      String message, {
        IconData icon = Icons.info_outline,
      }) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(14),
        duration: const Duration(seconds: 3),
        content: Row(
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _popSafe() {
    if (!mounted) return;
    if (_didPop) return;
    _didPop = true;
    Navigator.maybePop(context);
  }

  void _cancelRingTimeout() {
    _ringTimeout?.cancel();
    _ringTimeout = null;
  }

  void _startCallerRingTimeout() {
    _cancelRingTimeout();

    // ✅ Only for caller: after 10s still ringing -> stop
    if (!widget.isCaller) return;

    _ringTimeout = Timer(const Duration(seconds: 10), () async {
      if (!mounted) return;

      final s = AudioCallService.I.callState.value;
      if (s == 'ringing') {
        setState(() => _status = 'No answer');
        _showPrettySnack('No answer (10s).', icon: Icons.access_time);
        try {
          await AudioCallService.I.hangUp(localOnly: false);
        } catch (_) {}
        _popSafe();
      }
    });
  }

  Future<void> _onCallState() async {
    if (!mounted) return;
    final s = AudioCallService.I.callState.value;

    if (s == 'ringing') {
      setState(() => _status = 'Ringing…');
      _startCallerRingTimeout();
      return;
    }

    if (s == 'accepted') {
      _cancelRingTimeout();
      _setInCallPresence(true);

      setState(() {
        _status = 'Connected ✅';
        _callReady = true;
        _incomingWaiting = false;
        _cameraOn = AudioCallService.I.withVideo;
      });
      _bindStreams();
      if (_timer == null) _startTimer();
      // 🔊 Force speaker ON on Android (debug / stability)
      _speakerOn = true;
      await AudioCallService.I.setSpeakerOn(true);
      return;
    }

    if (s == 'busy') {
      _cancelRingTimeout();
      _setInCallPresence(false);

      setState(() => _status = 'Busy');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showPrettySnack('User is busy right now.', icon: Icons.schedule);
        _popSafe();
      });
      return;
    }

    if (s == 'no_answer') {
      _cancelRingTimeout();
      _setInCallPresence(false);

      _timer?.cancel();
      _timer = null;
      setState(() => _status = 'No answer');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showPrettySnack('No answer. Please try again.', icon: Icons.access_time);
        _popSafe();
      });
      return;
    }

    if (s == 'declined') {
      _cancelRingTimeout();
      _setInCallPresence(false);

      setState(() => _status = 'Declined');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showPrettySnack('Call declined.', icon: Icons.block);
        _popSafe();
      });
      return;
    }

    if (s == 'ended') {
      _cancelRingTimeout();
      _setInCallPresence(false);

      _timer?.cancel();
      _timer = null;
      setState(() => _status = 'Ended');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _popSafe();
      });
      return;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _cancelRingTimeout();

    // clear busy presence
    _setInCallPresence(false);

    AudioCallService.I.callState.removeListener(_onCallState);
    AudioCallService.I.localStreamVN.removeListener(_bindStreams);
    AudioCallService.I.remoteStreamVN.removeListener(_bindStreams);
    AudioCallService.I.chatMessages.removeListener(_onChatChanged);
    AudioCallService.I.videoOnRequestFromUid.removeListener(_onVideoRequest);

    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _msgCtrl.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  Future<void> _startOnce() async {
    if (_started) return;
    _started = true;
    await _start();
  }

  Future<void> _start() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (!mounted) return;
      _showPrettySnack('Microphone permission denied.', icon: Icons.mic_off);
      _popSafe();
      return;
    }

    try {
      if (widget.isCaller) {
        final callerName = (widget.callerName ?? '').trim().isEmpty
            ? 'Caller'
            : widget.callerName!.trim();

        final wantVideo = widget.startWithVideo;
        setState(() => _status = wantVideo ? 'Calling (video)…' : 'Calling…');

        await AudioCallService.I.startCall(
          calleeUid: widget.peerUid,
          callerName: callerName,
          withVideo: wantVideo,
        );

        if (!mounted) return;
        setState(() {
          _status = 'Ringing…';
          _callReady = true;
          _cameraOn = wantVideo;
        });

        _startCallerRingTimeout();
        await _bindStreams();
      } else {
        setState(() {
          _incomingWaiting = true;
          _callReady = false;
          _status = 'Incoming call…';
        });
      }
    } catch (e) {
      if (!mounted) return;

      final raw = e.toString();
      final msg = raw.replaceFirst('Exception: ', '').trim();
      _showPrettySnack(
        msg.isEmpty ? 'Something went wrong. Please try again.' : msg,
        icon: Icons.error_outline,
      );

      _popSafe();
    }
  }

  Future<void> _acceptIncoming() async {
    final callId = widget.incomingCallId?.trim();
    if (callId == null || callId.isEmpty) return;

    setState(() {
      _incomingWaiting = false;
      _status = 'Connecting…';
    });

    try {
      await AudioCallService.I.joinCall(callId: callId);
      if (!mounted) return;

      if (AudioCallService.I.callState.value != 'accepted') return;

      _setInCallPresence(true);

      setState(() {
        _status = 'Connected ✅';
        _callReady = true;
        _cameraOn = AudioCallService.I.withVideo;
      });
      await _bindStreams();
      _startTimer();
    } catch (_) {
      if (!mounted) return;
      _popSafe();
    }
  }

  Future<void> _declineIncoming() async {
    final callId = widget.incomingCallId?.trim();
    try {
      if (callId != null && callId.isNotEmpty) {
        await AudioCallService.I.declineCall(callId);
      } else {
        await AudioCallService.I.hangUp(localOnly: true);
      }
    } catch (_) {}

    _setInCallPresence(false);

    if (!mounted) return;
    _popSafe();
  }

  void _startTimer() {
    _timer?.cancel();
    _seconds = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _seconds++);
    });
  }

  String _formatTime(int s) {
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  Future<void> _hangup() async {
    _cancelRingTimeout();
    setState(() => _status = 'Ending…');
    await AudioCallService.I.hangUp(localOnly: false);
    _setInCallPresence(false);
  }

  void _toggleMute() {
    if (!_callReady) return;
    setState(() => _muted = !_muted);
    AudioCallService.I.setMuted(_muted);
  }

  Future<void> _toggleSpeaker() async {
    if (!_callReady) return;
    setState(() => _speakerOn = !_speakerOn);
    await AudioCallService.I.setSpeakerOn(_speakerOn);
  }

  Future<void> _toggleCamera() async {
    if (!_callReady) return;
    if (!_cameraOn) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        _showPrettySnack('Camera permission denied.', icon: Icons.videocam_off);
        return;
      }
      try {
        await AudioCallService.I.enableVideo();
        await _bindStreams();
        if (!mounted) return;
        setState(() => _cameraOn = true);
      } catch (_) {}
      return;
    }
    await AudioCallService.I.disableVideo();
    if (!mounted) return;
    setState(() => _cameraOn = false);
  }

  Future<void> _switchCamera() async {
    if (!_callReady || !_cameraOn) return;
    await AudioCallService.I.switchCamera();
  }

  Future<void> _sendMessage() async {
    if (!_callReady) return;
    final t = _msgCtrl.text.trim();
    if (t.isEmpty) return;
    _msgCtrl.clear();
    await AudioCallService.I.sendChatMessage(t);
  }

  Widget _chatBubble(AudioChatMessage m) {
    final isMe = m.fromMe;
    final bg = isMe ? const Color(0xFF1E88E5) : const Color(0xFF2E7D32);
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 240),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14).copyWith(
            bottomRight: isMe ? const Radius.circular(0) : null,
            bottomLeft: !isMe ? const Radius.circular(0) : null,
          ),
        ),
        child: Text(
          m.text,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  bool _videoDialogOpen = false;

  Future<void> _onVideoRequest() async {
    if (!mounted) return;

    final from = AudioCallService.I.videoOnRequestFromUid.value;
    if (from == null) return;

    if (_videoDialogOpen) return;

    if (AudioCallService.I.callState.value != 'accepted') {
      AudioCallService.I.clearVideoOnRequest();
      return;
    }

    if (_cameraOn) {
      AudioCallService.I.clearVideoOnRequest();
      return;
    }

    _videoDialogOpen = true;

    final peerName =
    widget.peerName.trim().isEmpty ? 'The other person' : widget.peerName.trim();

    final res = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return AlertDialog(
          title: const Text('Video request'),
          content: Text('$peerName turned on video.\nDo you want to turn on your camera too?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not now'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Turn on'),
            ),
          ],
        );
      },
    );

    _videoDialogOpen = false;
    AudioCallService.I.clearVideoOnRequest();

    if (res == true) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        _showPrettySnack('Camera permission denied.', icon: Icons.videocam_off);
        return;
      }

      try {
        await AudioCallService.I.enableVideo();
        await _bindStreams();
        if (!mounted) return;
        setState(() => _cameraOn = true);
      } catch (_) {}
    }
  }

  Widget _sideActionButton({
    required IconData icon,
    required Color color,
    required VoidCallback? onTap,
    bool isActive = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: isActive ? color : Colors.white.withOpacity(0.9),
            shape: BoxShape.circle,
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))
            ],
          ),
          child: Icon(icon, color: isActive ? Colors.white : color, size: 26),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.peerName.trim().isEmpty ? 'User' : widget.peerName.trim();
    final isConnected = AudioCallService.I.callState.value == 'accepted';
    final msgs = AudioCallService.I.chatMessages.value;

    final viewPadding = MediaQuery.of(context).viewPadding;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    final remoteHasVideo = (_remoteRenderer.srcObject?.getVideoTracks().isNotEmpty ?? false);
    final showRemoteVideo = remoteHasVideo;

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Text(peer, style: const TextStyle(fontWeight: FontWeight.w900)),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: const Color(0xFF1A2B48),
      ),
      body: Stack(
        children: [

          Positioned.fill(
            child: showRemoteVideo
                ? RTCVideoView(
              _remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            )
                : Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircleAvatar(
                    radius: 60,
                    backgroundColor: const Color(0xFF1A2B48),
                    child: Text(
                      peer.isNotEmpty ? peer[0].toUpperCase() : '?',
                      style: const TextStyle(fontSize: 40, color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _status,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  if (isConnected)
                    Text(
                      _formatTime(_seconds),
                      style: const TextStyle(fontSize: 18, color: Colors.blueGrey),
                    ),
                ],
              ),
            ),
          ),

          Positioned(
            left: 16,
            top: 16,
            child: Column(
              children: [
                _sideActionButton(
                  icon: _cameraOn ? Icons.videocam_off : Icons.videocam,
                  color: const Color(0xFF2E7D32),
                  isActive: _cameraOn,
                  onTap: _callReady ? _toggleCamera : null,
                ),
                if (_cameraOn)
                  _sideActionButton(
                    icon: Icons.cameraswitch,
                    color: const Color(0xFFFF8F00),
                    onTap: _callReady ? _switchCamera : null,
                  ),
                _sideActionButton(
                  icon: _speakerOn ? Icons.volume_up : Icons.hearing,
                  color: const Color(0xFF6A1B9A),
                  isActive: _speakerOn,
                  onTap: _callReady ? _toggleSpeaker : null,
                ),
                _sideActionButton(
                  icon: _muted ? Icons.mic_off : Icons.mic,
                  color: const Color(0xFF1565C0),
                  isActive: !_muted,
                  onTap: _callReady ? _toggleMute : null,
                ),
              ],
            ),
          ),

          if (_cameraOn && _localRenderer.srcObject != null)
            Positioned(
              right: 16,
              top: 16,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  width: 100,
                  height: 140,
                  color: Colors.black,
                  child: RTCVideoView(
                    _localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),

          if (!_incomingWaiting && msgs.isNotEmpty)
            Positioned(
              left: 16,
              right: 16,
              bottom: bottomInset + 160,
              child: Container(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  controller: _chatScroll,
                  itemCount: msgs.length,
                  itemBuilder: (_, i) => _chatBubble(msgs[i]),
                ),
              ),
            ),

          if (_incomingWaiting) _buildIncomingPopup(peer),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                (bottomInset > 0) ? bottomInset + 10 : viewPadding.bottom + 20,
              ),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 15,
                    offset: const Offset(0, -2),
                  )
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_incomingWaiting) ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _msgCtrl,
                            onSubmitted: (_) => _sendMessage(),
                            decoration: InputDecoration(
                              hintText: 'Type a message...',
                              filled: true,
                              fillColor: Colors.grey.shade100,
                              contentPadding:
                              const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(30),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          onPressed: _callReady ? _sendMessage : null,
                          icon: const Icon(Icons.send),
                          style: IconButton.styleFrom(
                            backgroundColor: const Color(0xFF1A2B48),
                            minimumSize: const Size(48, 48),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                  SizedBox(
                    width: double.infinity,
                    height: 58,
                    child: ElevatedButton.icon(
                      onPressed: _incomingWaiting ? _declineIncoming : _hangup,
                      icon: const Icon(Icons.call_end, color: Colors.white, size: 28),
                      label: Text(
                        _incomingWaiting ? 'DECLINE' : 'HANG UP',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD32F2F),
                        elevation: 4,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIncomingPopup(String peer) {
    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Incoming Call', style: TextStyle(fontSize: 16, color: Colors.grey)),
                const SizedBox(height: 8),
                Text(peer, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _acceptIncoming,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          padding: const EdgeInsets.all(16),
                        ),
                        child: const Text('Accept', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _declineIncoming,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          padding: const EdgeInsets.all(16),
                        ),
                        child: const Text('Decline', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                )
              ],
            ),
          ),
        ),
      ),
    );
  }
}
