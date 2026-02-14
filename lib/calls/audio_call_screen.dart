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
    this.callerName,
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
  bool _speakerOn = false;

  bool _started = false; // ✅ prevents double-start
  bool _callReady = false; // ✅ enables controls after tracks exist
  String _status = 'Starting…';

  Timer? _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _startOnce();
  }

  @override
  void dispose() {
    _timer?.cancel();
    // ✅ Best-effort: end call when screen is closed
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
          _callReady = true;
        });
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
        });

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
    setState(() => _status = 'Ended');
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
    try {
      await AudioCallService.I.setSpeakerOn(_speakerOn);
    } catch (_) {}
  }

  void _inviteOthersPlaceholder() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite others: coming soon')),
    );
  }

  void _videoLaterPlaceholder() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Video: coming later')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.peerName.trim().isEmpty ? 'User' : widget.peerName.trim();
    final subtitle = widget.isCaller ? 'Outgoing call' : 'Audio call';

    final isConnected = _status.toLowerCase().contains('connected');
    if (isConnected && _timer == null) {
      // Start timer once, safely, without changing the call logic.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_timer == null && mounted) _startTimer();
      });
    }

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: Text(peer),
        centerTitle: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
          child: Column(
            children: [
              const SizedBox(height: 10),

              // Top card: avatar + status
              _TopCard(
                name: peer,
                subtitle: subtitle,
                statusText: _status,
                timerText: isConnected ? _formatTime(_seconds) : null,
              ),

              const SizedBox(height: 18),

              // Controls grid
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    alignment: WrapAlignment.center,
                    children: [
                      _ActionTile(
                        label: _muted ? 'Unmute' : 'Mute',
                        icon: _muted ? Icons.mic_off : Icons.mic,
                        onTap: _callReady ? _toggleMute : null,
                        active: _muted,
                      ),
                      _ActionTile(
                        label: _speakerOn ? 'Speaker' : 'Earpiece',
                        icon: _speakerOn ? Icons.volume_up : Icons.hearing,
                        onTap: _callReady ? _toggleSpeaker : null,
                        active: _speakerOn,
                      ),
                      _ActionTile(
                        label: 'Invite',
                        icon: Icons.person_add,
                        onTap: _callReady ? _inviteOthersPlaceholder : null,
                      ),
                      _ActionTile(
                        label: 'Video (later)',
                        icon: Icons.videocam,
                        onTap: _callReady ? _videoLaterPlaceholder : null,
                      ),
                    ],
                  ),
                ),
              ),

              // Big hang up button
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: _hangup,
                  icon: const Icon(Icons.call_end),
                  label: const Text(
                    'Hang up',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopCard extends StatelessWidget {
  const _TopCard({
    required this.name,
    required this.subtitle,
    required this.statusText,
    this.timerText,
  });

  final String name;
  final String subtitle;
  final String statusText;
  final String? timerText;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            blurRadius: 18,
            spreadRadius: 0,
            offset: const Offset(0, 8),
            color: Colors.black.withOpacity(0.06),
          ),
        ],
      ),
      child: Column(
        children: [
          CircleAvatar(
            radius: 38,
            backgroundColor: cs.primary.withOpacity(0.12),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w900,
                color: cs.primary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            name,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withOpacity(0.65),
            ),
          ),
          const SizedBox(height: 12),

          // Status chip + timer
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              _Chip(
                icon: Icons.circle,
                iconColor: statusText.toLowerCase().contains('connected')
                    ? Colors.green
                    : cs.primary,
                text: statusText,
              ),
              if (timerText != null)
                _Chip(
                  icon: Icons.timer,
                  iconColor: cs.onSurface.withOpacity(0.7),
                  text: timerText!,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.iconColor,
    required this.text,
  });

  final IconData icon;
  final Color iconColor;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.onSurface.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: iconColor),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: cs.onSurface.withOpacity(0.9),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.label,
    required this.icon,
    required this.onTap,
    this.active = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = onTap != null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Ink(
        width: 160,
        height: 90,
        decoration: BoxDecoration(
          color: enabled
              ? (active ? cs.primary.withOpacity(0.12) : cs.surfaceContainerHighest)
              : cs.surfaceContainerHighest.withOpacity(0.5),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: active ? cs.primary.withOpacity(0.35) : cs.onSurface.withOpacity(0.08),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: active ? cs.primary.withOpacity(0.14) : cs.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cs.onSurface.withOpacity(0.08)),
                ),
                child: Icon(
                  icon,
                  color: enabled ? (active ? cs.primary : cs.onSurface) : cs.onSurface.withOpacity(0.35),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: enabled ? cs.onSurface : cs.onSurface.withOpacity(0.35),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
