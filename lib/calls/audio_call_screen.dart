import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'audio_call_service.dart';

class AudioCallScreen extends StatefulWidget {
  const AudioCallScreen({
    super.key,
    required this.peerUid,
    required this.peerName,
    required this.isCaller,
    this.incomingCallId,
    this.callerName, // ✅ caller display name (used only when isCaller=true)
  });

  final String peerUid;
  final String peerName;
  final bool isCaller;

  /// For callee (opened from notification)
  final String? incomingCallId;

  /// For caller side push payload (AudioCallService.startCall needs it)
  final String? callerName;

  @override
  State<AudioCallScreen> createState() => _AudioCallScreenState();
}

class _AudioCallScreenState extends State<AudioCallScreen> {
  bool _muted = false;
  bool _started = false; // ✅ prevents double-start
  bool _callReady = false; // ✅ enables mute after tracks exist
  String _status = 'Starting…';

  @override
  void initState() {
    super.initState();
    _startOnce();
  }

  @override
  void dispose() {
    // ✅ Best-effort: end call when screen is closed
    // localOnly=false will also mark DB status ended (safe)
    AudioCallService.I.hangUp(localOnly: false);
    super.dispose();
  }

  Future<void> _startOnce() async {
    if (_started) return;
    _started = true;
    await _start();
  }

  Future<void> _start() async {
    // 1) Permission
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission denied.')),
      );
      Navigator.maybePop(context);
      return;
    }

    try {
      if (widget.isCaller) {
        // 2) Caller path: startCall(calleeUid, callerName)
        final name = (widget.callerName ?? '').trim();
        final callerName = name.isEmpty ? 'Caller' : name;

        setState(() => _status = 'Calling…');

        await AudioCallService.I.startCall(
          calleeUid: widget.peerUid,
          callerName: callerName,
        );

        if (!mounted) return;
        setState(() {
          _status = 'Ringing…';
          _callReady = true; // offer created + local tracks exist
        });
      } else {
        // 3) Callee path: joinCall(incomingCallId)
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
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Call error: $e')),
      );
      Navigator.maybePop(context);
    }
  }

  Future<void> _hangup() async {
    setState(() => _status = 'Ending…');

    await AudioCallService.I.hangUp(localOnly: false);

    if (!mounted) return;
    setState(() => _status = 'Ended');
    Navigator.maybePop(context);
  }

  void _toggleMute() {
    if (!_callReady) return;
    setState(() => _muted = !_muted);
    AudioCallService.I.setMuted(_muted);
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.peerName.trim().isEmpty ? 'User' : widget.peerName.trim();
    final title = widget.isCaller ? 'Calling $peer' : 'Call with $peer';

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _status,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _callReady ? _toggleMute : null,
                    icon: Icon(_muted ? Icons.mic_off : Icons.mic),
                    label: Text(_muted ? 'Unmute' : 'Mute'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: _hangup,
                    icon: const Icon(Icons.call_end),
                    label: const Text('Hang up'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
