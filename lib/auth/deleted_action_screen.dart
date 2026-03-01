import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class DeletedActionScreen extends StatefulWidget {
  final String uid;
  final bool deleteAuth;
  final bool selfDeleteDone;

  const DeletedActionScreen({
    super.key,
    required this.uid,
    required this.deleteAuth,
    required this.selfDeleteDone,
  });

  @override
  State<DeletedActionScreen> createState() => _DeletedActionScreenState();
}

class _DeletedActionScreenState extends State<DeletedActionScreen> {
  bool _ran = false;
  bool _loading = true;

  Map<String, dynamic> _data = {};
  String _status = 'Loading deleted account…';
  String? _error;
  bool _forceDelete = false;

  DatabaseReference get _ref =>
      FirebaseDatabase.instance.ref('users_deleted/${widget.uid}');

  void _setStatus(String s) {
    debugPrint('FIKRA_DELETED | $s');
    if (mounted) setState(() => _status = s);
  }

  Future<void> _load() async {
    try {
      final snap = await _ref.get();
      if (!snap.exists) {
        // User not in users_deleted → force auth deletion
        setState(() {
          _forceDelete = true;
          _loading = false;
        });
        return;
      }


      final raw = snap.value;
      final m = raw is Map
          ? raw.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

      setState(() {
        _data = Map<String, dynamic>.from(m);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _signOut() async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
  }

  Future<void> _deleteAuthIfNeeded() async {
    // source of truth: data from RTDB (fallback to widget flags)
    final deleteAuth =
        _forceDelete ||
            (_data['deleteAuth'] == true) ||
            widget.deleteAuth == true;
    final selfDeleteDone =
        (_data['selfDeleteDone'] == true) || widget.selfDeleteDone == true;

    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      _setStatus('Already signed out.');
      return;
    }

    if (selfDeleteDone) {
      _setStatus('Deletion already finalized. Signing out…');
      return;
    }

    if (!deleteAuth) {
      _setStatus('Account removed. Signing out…');
      return;
    }

    try {
      _setStatus('Finalizing deletion…');
      await user.reload();
      final fresh = FirebaseAuth.instance.currentUser;

      await fresh?.delete(); // may fail requires-recent-login
      _setStatus('Auth user deleted ✅');

      await _ref.update({
        'selfDeleteDone': true,
        'selfDeleteDoneAt': ServerValue.timestamp,
      });

      _setStatus('Marked as done ✅');
    } on FirebaseAuthException catch (e) {
      if (e.code == 'requires-recent-login') {
        _setStatus('Needs recent login to delete auth. Signing out…');
      } else {
        _setStatus('Delete failed: ${e.code}');
      }
    } catch (e) {
      _setStatus('Delete failed: $e');
    }
  }

  Future<void> _run() async {
    if (_ran) return;
    _ran = true;

    await _load();
    if (_error != null) return;

    // ✅ IMPORTANT: let the UI render + user see details
    await Future.delayed(const Duration(milliseconds: 2500));

    await _deleteAuthIfNeeded();

    // ✅ let user see the status message
    await Future.delayed(const Duration(milliseconds: 1200));

    await _signOut();
  }

  @override
  void initState() {
    super.initState();
    // run after first frame so UI can show
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  String _v(String k) {
    final v = _data[k];
    if (v == null) return '-';
    final s = v.toString().trim();
    return s.isEmpty ? '-' : s;
  }

  Widget _row(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(k, style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
          Expanded(child: Text(v)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = ('${_v('first_name')} ${_v('last_name')}').trim();

    return Scaffold(
      appBar: AppBar(title: const Text('Account Removed')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(child: Text('Error:\n$_error'))
              : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.delete_forever_rounded, size: 72),
              const SizedBox(height: 10),
              Text(
                name.isEmpty ? 'Account removed' : '$name removed',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'This account has been removed.\nIf you think this is a mistake, contact the school.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),

              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.04),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.black.withOpacity(.08)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Details',
                        style: TextStyle(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 10),
                    _row('Serial', _v('serial')),
                    _row('Email', _v('email')),
                    _row('Role', _v('role')),
                    _row('Status', _v('status')),
                    _row('Phone', _v('phone1')),
                    _row('Moved From', _v('movedFrom')),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(.07),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue.withOpacity(.15)),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _status,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(),

              OutlinedButton.icon(
                onPressed: () => SystemNavigator.pop(),
                icon: const Icon(Icons.close),
                label: const Text('Close app'),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: () async {
                  await _signOut();
                },
                icon: const Icon(Icons.logout),
                label: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
