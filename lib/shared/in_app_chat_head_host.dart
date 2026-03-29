import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/push_client.dart';
import '../services/route_state.dart';
import 'profile_avatar.dart';

class InAppChatHeadHost extends StatefulWidget {
  const InAppChatHeadHost({super.key, required this.child});

  final Widget child;

  @override
  State<InAppChatHeadHost> createState() => _InAppChatHeadHostState();
}

class _InAppChatHeadHostState extends State<InAppChatHeadHost> {
  StreamSubscription<DatabaseEvent>? _sub;
  StreamSubscription<User?>? _authSub;

  String _meUid = '';
  String _meName = 'User';
  _UnreadThreadLite? _active;
  final Map<String, String> _peerPhotoCache = {};
  final Map<String, Future<void>> _peerPhotoPending = {};

  bool _sending = false;
  final TextEditingController _quickReplyC = TextEditingController();

  Offset _bubbleOffset = const Offset(20, 120);
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _attachForCurrentUser();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((_) {
      _attachForCurrentUser();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _authSub?.cancel();
    _quickReplyC.dispose();
    super.dispose();
  }

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return const <String, dynamic>{};
  }

  Future<void> _attachForCurrentUser() async {
    final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (uid == _meUid && _sub != null) return;

    await _sub?.cancel();
    _sub = null;

    _meUid = uid;
    _active = null;
    if (!mounted) return;
    setState(() {});

    if (uid.isEmpty) return;

    unawaited(_loadMyName(uid));
    final ref = FirebaseDatabase.instance.ref('mail_index/$uid');
    _sub = ref.onValue.listen((event) {
      final next = _pickUnreadThread(event.snapshot.value);
      if (!mounted) return;

      if (next == null || RouteState.currentMailThreadId == next.threadId) {
        if (_active != null) {
          setState(() => _active = null);
        }
        return;
      }

      final changed =
          _active == null ||
          _active!.threadId != next.threadId ||
          _active!.unreadCount != next.unreadCount ||
          _active!.updatedAt != next.updatedAt;

      if (changed) {
        setState(() => _active = next);
        unawaited(_ensurePeerPhoto(next.peerUid));
      }
    });
  }

  Future<void> _loadMyName(String uid) async {
    try {
      final snap = await FirebaseDatabase.instance.ref('users/$uid').get();
      final m = _asMap(snap.value);
      final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
      final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
      final full = ('$first $last').trim();
      final email = (m['email'] ?? '').toString().trim();
      final resolved = full.isNotEmpty
          ? full
          : (email.isNotEmpty ? email : 'User');
      if (!mounted) return;
      setState(() => _meName = resolved);
    } catch (_) {}
  }

  _UnreadThreadLite? _pickUnreadThread(dynamic value) {
    if (value is! Map) return null;
    final out = <_UnreadThreadLite>[];

    final root = value.map((k, v) => MapEntry(k.toString(), v));
    root.forEach((threadId, raw) {
      final m = _asMap(raw);
      final unread = _toInt(m['unreadCount']);
      if (unread <= 0) return;

      final peerUid = (m['peerUid'] ?? '').toString().trim();
      final peerName = (m['peerName'] ?? '').toString().trim();
      if (threadId.trim().isEmpty || peerUid.isEmpty) return;

      out.add(
        _UnreadThreadLite(
          threadId: threadId,
          peerUid: peerUid,
          peerName: peerName.isEmpty ? 'User' : peerName,
          subject: (m['subject'] ?? '').toString(),
          lastMessage: (m['lastMessage'] ?? '').toString(),
          updatedAt: _toInt(m['updatedAt']),
          unreadCount: unread,
        ),
      );
    });

    if (out.isEmpty) return null;
    out.sort((a, b) {
      if (a.updatedAt != b.updatedAt) return b.updatedAt.compareTo(a.updatedAt);
      return b.unreadCount.compareTo(a.unreadCount);
    });
    return out.first;
  }

  Future<Map<String, dynamic>> _fetchUserMap(String uid) async {
    final snap = await FirebaseDatabase.instance.ref('users/$uid').get();
    return _asMap(snap.value);
  }

  Future<void> _ensurePeerPhoto(String uid) {
    uid = uid.trim();
    if (uid.isEmpty || _peerPhotoCache.containsKey(uid)) return Future.value();

    final pending = _peerPhotoPending[uid];
    if (pending != null) return pending;

    final fut = () async {
      try {
        final m = await _fetchUserMap(uid);
        final p = ProfileAvatar.resolvePhotoFromMap(m);
        final changed = _peerPhotoCache[uid] != p;
        _peerPhotoCache[uid] = p;
        if (changed && mounted) setState(() {});
      } catch (_) {
        _peerPhotoCache.putIfAbsent(uid, () => '');
      } finally {
        _peerPhotoPending.remove(uid);
      }
    }();

    _peerPhotoPending[uid] = fut;
    return fut;
  }

  Future<String?> _getFcmToken(String uid) async {
    final snap = await FirebaseDatabase.instance
        .ref('fcm_tokens/$uid/token')
        .get();
    final token = snap.value?.toString().trim();
    if (token == null || token.isEmpty) return null;
    return token;
  }

  Future<void> _sendQuickReply(_UnreadThreadLite target, String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty || _sending || _meUid.isEmpty) return;

    setState(() => _sending = true);
    try {
      final db = FirebaseDatabase.instance;
      final now = DateTime.now().millisecondsSinceEpoch;
      final preview80 = trimmed.length > 80
          ? trimmed.substring(0, 80)
          : trimmed;

      final msgRef = db.ref('mail_messages/${target.threadId}').push();
      await msgRef.set({
        'fromUid': _meUid,
        'body': trimmed,
        'toUids': {target.peerUid: true},
        'ccUids': {},
        'bccUids': {},
        'attachments': [],
        'createdAt': now,
        'deletedFor': {},
        'reactions': {},
      });

      await db.ref('mail_threads/${target.threadId}').update({
        'updatedAt': now,
        'lastMessage': preview80,
      });

      await db.ref('mail_index/$_meUid/${target.threadId}').update({
        'subject': target.subject,
        'updatedAt': now,
        'lastMessage': preview80,
        'unreadCount': 0,
        'peerUid': target.peerUid,
        'peerName': target.peerName,
        'deletedAt': null,
      });

      await db
          .ref('mail_index/${target.peerUid}/${target.threadId}')
          .runTransaction((cur) {
            final m = _asMap(cur);
            final oldUnread = _toInt(m['unreadCount']);
            m['subject'] = target.subject;
            m['updatedAt'] = now;
            m['lastMessage'] = preview80;
            m['unreadCount'] = oldUnread + 1;
            m['peerUid'] = _meUid;
            m['peerName'] = _meName;
            m['deletedAt'] = null;
            return Transaction.success(m);
          });

      _quickReplyC.clear();

      final token = await _getFcmToken(target.peerUid);
      if (token != null) {
        await PushClient.sendToToken(
          token: token,
          title: target.subject.trim().isEmpty
              ? 'New mail'
              : target.subject.trim(),
          message: preview80,
          data: {
            'type': 'mail',
            'route': 'mail_thread',
            'threadId': target.threadId,
            'peerUid': _meUid,
          },
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send quick reply.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openMiniChat(_UnreadThreadLite target) async {
    final peerUser = await _fetchUserMap(target.peerUid);
    if (!mounted) return;

    final photo = ProfileAvatar.resolvePhotoFromMap(peerUser);
    final latest = target.lastMessage.trim().isEmpty
        ? 'No messages yet'
        : target.lastMessage.trim();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final inset = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + inset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ProfileAvatar(
                    name: target.peerName,
                    photoUrl: photo,
                    radius: 20,
                    fallbackBg: const Color(0xFFEAF2FF),
                    fallbackFg: const Color(0xFF1A2B48),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          target.peerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF1A2B48),
                            fontSize: 16,
                          ),
                        ),
                        if (target.subject.trim().isNotEmpty)
                          Text(
                            target.subject.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF4F5F75),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF2E7),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${target.unreadCount}',
                      style: const TextStyle(
                        color: Color(0xFFF98D28),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F7F9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFD1D9E0)),
                ),
                child: Text(
                  latest,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2D2D2D),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _quickReplyC,
                      maxLines: 3,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (v) async {
                        await _sendQuickReply(target, v);
                        if (!ctx.mounted) return;
                        if (_quickReplyC.text.trim().isEmpty) {
                          Navigator.pop(ctx);
                        }
                      },
                      decoration: InputDecoration(
                        hintText: 'Quick reply...',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _sending
                        ? null
                        : () async {
                            await _sendQuickReply(target, _quickReplyC.text);
                            if (!ctx.mounted) return;
                            if (_quickReplyC.text.trim().isEmpty) {
                              Navigator.pop(ctx);
                            }
                          },
                    child: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final head = _active;
    if (head != null) {
      unawaited(_ensurePeerPhoto(head.peerUid));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxX = (constraints.maxWidth - 64).clamp(8.0, double.infinity);
        final maxY = (constraints.maxHeight - 120).clamp(8.0, double.infinity);
        final clamped = Offset(
          _bubbleOffset.dx.clamp(8.0, maxX),
          _bubbleOffset.dy.clamp(8.0, maxY),
        );

        if (clamped != _bubbleOffset) {
          _bubbleOffset = clamped;
        }

        return Stack(
          children: [
            widget.child,
            if (head != null)
              Positioned(
                left: _bubbleOffset.dx,
                top: _bubbleOffset.dy,
                child: GestureDetector(
                  onPanStart: (_) => setState(() => _dragging = true),
                  onPanUpdate: (d) {
                    setState(() {
                      _bubbleOffset = Offset(
                        (_bubbleOffset.dx + d.delta.dx).clamp(8.0, maxX),
                        (_bubbleOffset.dy + d.delta.dy).clamp(8.0, maxY),
                      );
                    });
                  },
                  onPanEnd: (_) => setState(() => _dragging = false),
                  onTap: () async {
                    if (_dragging) return;
                    await _openMiniChat(head);
                  },
                  onLongPress: () {
                    setState(() => _active = null);
                  },
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFFD1D9E0)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.16),
                            blurRadius: 14,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: ProfileAvatar(
                                name: head.peerName,
                                photoUrl: _peerPhotoCache[head.peerUid] ?? '',
                                radius: 25,
                                fallbackBg: const Color(0xFFEAF2FF),
                                fallbackFg: const Color(0xFF1A2B48),
                              ),
                            ),
                          ),
                          Positioned(
                            right: -2,
                            top: -2,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF98D28),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                head.unreadCount > 99
                                    ? '99+'
                                    : '${head.unreadCount}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _UnreadThreadLite {
  const _UnreadThreadLite({
    required this.threadId,
    required this.peerUid,
    required this.peerName,
    required this.subject,
    required this.lastMessage,
    required this.updatedAt,
    required this.unreadCount,
  });

  final String threadId;
  final String peerUid;
  final String peerName;
  final String subject;
  final String lastMessage;
  final int updatedAt;
  final int unreadCount;
}
