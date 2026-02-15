import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'audio_call_service.dart';

class AudioCallScreen extends StatefulWidget {
  const AudioCallScreen({
    super.key,
    required this.peerUid,
    required this.peerName,
    required this.isCaller,
    this.incomingCallId,
    this.callerName,
    this.startWithVideo = false, // ✅ THIS fixes your error
  });

  final String peerUid;
  final String peerName;
  final bool isCaller;

  final String? incomingCallId;
  final String? callerName;

  /// ✅ if true => start as video call
  final bool startWithVideo;

  @override
  State<AudioCallScreen> createState() => _AudioCallScreenState();
}

class _AudioCallScreenState extends State<AudioCallScreen> {
  bool _muted = false;
  bool _speakerOn = false;

  bool _cameraOn = false;
  bool _captionsOn = false;

  bool _started = false;
  bool _callReady = false;
  String _status = 'Starting…';

  Timer? _timer;
  int _seconds = 0;

  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;

  @override
  void initState() {
    super.initState();
    AudioCallService.I.callState.addListener(_onCallState);
    AudioCallService.I.remoteCaption.addListener(_onCaptionChanged);
    _startOnce();
  }

  void _onCaptionChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onCallState() {
    if (!mounted) return;

    final s = AudioCallService.I.callState.value;

    if (s == 'ringing') {
      if (_status != 'Ringing…') setState(() => _status = 'Ringing…');
      return;
    }

    if (s == 'accepted') {
      if (_status != 'Connected ✅') {
        setState(() {
          _status = 'Connected ✅';
          _callReady = true;
        });
      }
      _ensureRenderersBound();
      if (_timer == null) _startTimer();
      return;
    }

    if (s == 'ended') {
      _timer?.cancel();
      _timer = null;
      if (_status != 'Ended') setState(() => _status = 'Ended');

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.maybePop(context);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    AudioCallService.I.callState.removeListener(_onCallState);
    AudioCallService.I.remoteCaption.removeListener(_onCaptionChanged);

    _localRenderer?.dispose();
    _remoteRenderer?.dispose();

    AudioCallService.I.hangUp(localOnly: false);
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission denied.')),
      );
      Navigator.maybePop(context);
      return;
    }

    final wantVideo = widget.startWithVideo;

    if (wantVideo) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission denied. (Starting audio only)')),
        );
      }
    }

    try {
      if (widget.isCaller) {
        final name = (widget.callerName ?? '').trim();
        final callerName = name.isEmpty ? 'Caller' : name;

        setState(() => _status = wantVideo ? 'Starting video…' : 'Calling…');

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

        _ensureRenderersBound();
      } else {
        final callId = widget.incomingCallId?.trim();
        if (callId == null || callId.isEmpty) {
          throw Exception('Missing incoming callId.');
        }

        setState(() => _status = 'Connecting…');

        await AudioCallService.I.joinCall(callId: callId);

        if (!mounted) return;
        setState(() {
          _status = 'Connected ✅';
          _callReady = true;
          _cameraOn = AudioCallService.I.withVideo;
        });

        _ensureRenderersBound();
        _startTimer();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Call error: $e')),
      );
      Navigator.maybePop(context);
    }
  }

  Future<void> _ensureRenderersBound() async {
    final withVideo = AudioCallService.I.withVideo;
    if (!withVideo) return;

    _localRenderer ??= RTCVideoRenderer();
    _remoteRenderer ??= RTCVideoRenderer();

    await _localRenderer!.initialize();
    await _remoteRenderer!.initialize();


    final local = AudioCallService.I.localStream;
    final remote = AudioCallService.I.remoteStream;

    if (local != null) _localRenderer!.srcObject = local;
    if (remote != null) _remoteRenderer!.srcObject = remote;

    if (mounted) setState(() {});
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
    setState(() => _status = 'Ending…');
    await AudioCallService.I.hangUp(localOnly: false);
    if (!mounted) return;
    Navigator.maybePop(context);
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

  void _toggleCamera() {
    if (!_callReady) return;
    if (!AudioCallService.I.withVideo) return;
    setState(() => _cameraOn = !_cameraOn);
    AudioCallService.I.setCameraEnabled(_cameraOn);
  }

  Future<void> _switchCamera() async {
    if (!_callReady) return;
    if (!AudioCallService.I.withVideo) return;
    await AudioCallService.I.switchCamera();
  }

  Future<void> _toggleCaptions() async {
    if (!_callReady) return;
    setState(() => _captionsOn = !_captionsOn);
  }

  Future<void> _sendCaption() async {
    if (!_callReady) return;

    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Send caption'),
        content: TextField(
          controller: c,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Type text…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send'),
          ),
        ],
      ),
    ) ??
        false;

    if (!ok) return;
    await AudioCallService.I.sendCaption(c.text);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.peerName.trim().isEmpty ? 'User' : widget.peerName.trim();
    final isConnected = _status.toLowerCase().contains('connected');

    final withVideo = AudioCallService.I.withVideo;
    final remoteCap = AudioCallService.I.remoteCaption.value.trim();

    return Scaffold(
      appBar: AppBar(title: Text(peer), centerTitle: true),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: withVideo && _remoteRenderer?.srcObject != null
                      ? RTCVideoView(
                    _remoteRenderer!,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  )
                      : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 44,
                          child: Text(peer.isNotEmpty ? peer[0].toUpperCase() : '?'),
                        ),
                        const SizedBox(height: 12),
                        Text(_status, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                        if (isConnected) ...[
                          const SizedBox(height: 6),
                          Text(_formatTime(_seconds), style: const TextStyle(fontSize: 16)),
                        ],
                      ],
                    ),
                  ),
                ),
                if (withVideo && _localRenderer?.srcObject != null)
                  Positioned(
                    right: 12,
                    top: 12,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: 120,
                        height: 160,
                        child: RTCVideoView(
                          _localRenderer!,
                          mirror: true,
                          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        ),
                      ),
                    ),
                  ),
                if (_captionsOn && remoteCap.isNotEmpty)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        remoteCap,
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                ElevatedButton.icon(
                  onPressed: _callReady ? _toggleMute : null,
                  icon: Icon(_muted ? Icons.mic_off : Icons.mic),
                  label: Text(_muted ? 'Unmute' : 'Mute'),
                ),
                ElevatedButton.icon(
                  onPressed: _callReady ? _toggleSpeaker : null,
                  icon: Icon(_speakerOn ? Icons.volume_up : Icons.hearing),
                  label: Text(_speakerOn ? 'Speaker' : 'Earpiece'),
                ),
                ElevatedButton.icon(
                  onPressed: _callReady ? _toggleCaptions : null,
                  icon: const Icon(Icons.closed_caption),
                  label: Text(_captionsOn ? 'Captions On' : 'Captions Off'),
                ),
                ElevatedButton.icon(
                  onPressed: (_callReady && _captionsOn) ? _sendCaption : null,
                  icon: const Icon(Icons.edit),
                  label: const Text('Send text'),
                ),
                if (withVideo) ...[
                  ElevatedButton.icon(
                    onPressed: _callReady ? _toggleCamera : null,
                    icon: Icon(_cameraOn ? Icons.videocam : Icons.videocam_off),
                    label: Text(_cameraOn ? 'Cam On' : 'Cam Off'),
                  ),
                  ElevatedButton.icon(
                    onPressed: _callReady ? _switchCamera : null,
                    icon: const Icon(Icons.cameraswitch),
                    label: const Text('Flip'),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: _hangup,
                icon: const Icon(Icons.call_end),
                label: const Text('Hang up'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
