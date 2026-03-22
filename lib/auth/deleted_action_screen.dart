import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../shared/human_error.dart';

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
  bool _busy = false;
  bool _forceDelete = false;

  Map<String, dynamic> _data = {};
  String _status = 'Preparing account removal…';
  String? _error;

  DatabaseReference get _ref =>
      FirebaseDatabase.instance.ref('users_deleted/${widget.uid}');

  void _log(String msg) {
    // intentionally quiet in production
  }

  void _setStatus(String s) {
    _log(s);
    if (!mounted) return;
    setState(() => _status = s);
  }

  bool _asBool(dynamic v) {
    if (v == true) return true;
    final s = v?.toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }

  String _asText(dynamic v) {
    if (v == null) return '-';
    final s = v.toString().trim();
    return s.isEmpty ? '-' : s;
  }

  Future<void> _load() async {
    try {
      final snap = await _ref.get();

      if (!snap.exists) {
        if (!mounted) return;
        setState(() {
          _forceDelete = true;
          _loading = false;
          _data = {};
        });
        return;
      }

      final raw = snap.value;
      final m = raw is Map
          ? raw.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

      if (!mounted) return;
      setState(() {
        _data = Map<String, dynamic>.from(m);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e);
        _loading = false;
      });
    }
  }

  Future<void> _safeUpdateDeletedRecord(Map<String, dynamic> patch) async {
    try {
      await _ref.update(patch);
    } catch (e) {
      _log('RTDB update failed: $e');
      rethrow;
    }
  }

  Future<void> _signOut() async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      _log('Sign out failed: $e');
    }
  }

  Future<void> _closeApp() async {
    try {
      await SystemNavigator.pop();
    } catch (_) {}
  }

  Future<void> _runDeleteFlow() async {
    if (_busy) return;
    _busy = true;

    try {
      final deleteAuth =
          _forceDelete || _asBool(_data['deleteAuth']) || widget.deleteAuth;

      final selfDeleteDone =
          _asBool(_data['selfDeleteDone']) || widget.selfDeleteDone;

      final user = FirebaseAuth.instance.currentUser;

      if (user == null) {
        _setStatus('Already signed out.');
        return;
      }

      if (selfDeleteDone) {
        _setStatus('Deletion already finalized. Signing out…');
        await Future.delayed(const Duration(milliseconds: 900));
        await _signOut();
        return;
      }

      if (!deleteAuth) {
        _setStatus('Account removed. Signing out…');
        await Future.delayed(const Duration(milliseconds: 900));
        await _signOut();
        return;
      }

      _setStatus('Finalizing deletion…');

      // IMPORTANT:
      // Because client code may lose DB write access right after Auth delete,
      // we mark the record BEFORE deleting Auth, then REVERT if delete fails.
      //
      // This is the strongest client-only fix possible without a backend.
      await _safeUpdateDeletedRecord({
        'selfDeleteDone': true,
        'selfDeleteDoneAt': ServerValue.timestamp,
        'selfDeleteMarkedBy': 'client',
        'selfDeletePendingAuthDelete': true,
        'lastDeleteAttemptAt': ServerValue.timestamp,
      });

      _setStatus('Removing login access…');

      await user.reload();
      final fresh = FirebaseAuth.instance.currentUser;

      if (fresh == null) {
        throw Exception('User session disappeared before delete.');
      }

      await fresh.delete();

      _setStatus('Account fully removed ✅');

      // Best effort cleanup.
      // This may fail after auth deletion, so we do not depend on it.
      try {
        await _ref.update({
          'selfDeletePendingAuthDelete': false,
          'authDeletedAt': ServerValue.timestamp,
        });
      } catch (e) {
        _log('Post-delete cleanup skipped: $e');
      }

      await Future.delayed(const Duration(milliseconds: 1200));
      await _signOut();
    } on FirebaseAuthException catch (e) {
      _log('Auth delete error: ${e.code}');

      // Revert the optimistic flag because Auth deletion did NOT succeed.
      try {
        await _safeUpdateDeletedRecord({
          'selfDeleteDone': false,
          'selfDeleteDoneAt': null,
          'selfDeletePendingAuthDelete': false,
          'deleteError': e.code,
          'deleteErrorAt': ServerValue.timestamp,
          'lastDeleteAttemptAt': ServerValue.timestamp,
        });
      } catch (revertError) {
        _log('Revert failed: $revertError');
      }

      if (e.code == 'requires-recent-login') {
        _setStatus(
          'For security, the learner must log in again recently before account deletion can finish.',
        );
      } else if (e.code == 'user-not-found') {
        _setStatus('Login account was already removed ✅');
        try {
          await _safeUpdateDeletedRecord({
            'selfDeleteDone': true,
            'selfDeleteDoneAt': ServerValue.timestamp,
            'selfDeletePendingAuthDelete': false,
            'authDeletedAt': ServerValue.timestamp,
            'deleteError': null,
          });
        } catch (markError) {
          _log('Could not finalize after user-not-found: $markError');
        }
        await Future.delayed(const Duration(milliseconds: 1200));
        await _signOut();
      } else {
        _setStatus('Delete failed: ${e.code}');
      }
    } catch (e) {
      _log('Delete flow failed: $e');

      try {
        await _safeUpdateDeletedRecord({
          'selfDeleteDone': false,
          'selfDeleteDoneAt': null,
          'selfDeletePendingAuthDelete': false,
          'deleteError': e.toString(),
          'deleteErrorAt': ServerValue.timestamp,
          'lastDeleteAttemptAt': ServerValue.timestamp,
        });
      } catch (revertError) {
        _log('Revert failed: $revertError');
      }

      _setStatus('Delete failed. Please sign in again and retry.');
    } finally {
      _busy = false;
    }
  }

  Future<void> _run() async {
    if (_ran) return;
    _ran = true;

    await _load();
    if (_error != null) return;

    await Future.delayed(const Duration(milliseconds: 900));
    await _runDeleteFlow();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Widget _infoRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF1A2B48)),
          const SizedBox(width: 10),
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: Color(0xFF1A2B48),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Color(0xFF2D2D2D),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF4FF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFCFE3FF)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _status,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: Color(0xFF1A2B48),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    final first = _asText(_data['first_name']);
    final last = _asText(_data['last_name']);

    final name = [
      first,
      last,
    ].where((e) => e != '-' && e.trim().isNotEmpty).join(' ').trim();

    return Column(
      children: [
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [Color(0xFFF98D28), Color(0xFFFFB15C)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.10),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(
            Icons.delete_forever_rounded,
            size: 46,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          name.isEmpty ? 'Account removed' : '$name removed',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: Color(0xFF1A2B48),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'This account has been removed from the school app.\nIf this is a mistake, please contact the school.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.4,
            color: Colors.black.withOpacity(0.65),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _detailsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFD9E1E8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.badge_rounded, color: Color(0xFF1A2B48)),
              SizedBox(width: 8),
              Text(
                'Account details',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: Color(0xFF1A2B48),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _infoRow(
            icon: Icons.confirmation_number_rounded,
            label: 'Serial',
            value: _asText(_data['serial']),
          ),
          _infoRow(
            icon: Icons.mail_rounded,
            label: 'Email',
            value: _asText(_data['email']),
          ),
          _infoRow(
            icon: Icons.person_rounded,
            label: 'Role',
            value: _asText(_data['role']),
          ),
          _infoRow(
            icon: Icons.info_outline_rounded,
            label: 'Status',
            value: _asText(_data['status']),
          ),
          _infoRow(
            icon: Icons.phone_rounded,
            label: 'Phone',
            value: _asText(_data['phone1']),
          ),
          _infoRow(
            icon: Icons.move_down_rounded,
            label: 'Moved from',
            value: _asText(_data['movedFrom']),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F9),
      appBar: AppBar(
        title: const Text(
          'Account Removed',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: Color(0xFF1A2B48),
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: Color(0xFF1A2B48)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFD9E1E8)),
                    ),
                    child: Text(
                      'Error:\n$_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(),
                    const SizedBox(height: 18),
                    _detailsCard(),
                    const SizedBox(height: 14),
                    _statusCard(),
                    const SizedBox(height: 18),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: Color(0xFFD1D9E0)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xFF1A2B48),
                      ),
                      onPressed: _busy
                          ? null
                          : () async {
                              await _signOut();
                            },
                      icon: const Icon(Icons.logout_rounded),
                      label: const Text(
                        'Sign out',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: const Color(0xFFF98D28),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 0,
                      ),
                      onPressed: _busy
                          ? null
                          : () async {
                              await _closeApp();
                            },
                      icon: const Icon(Icons.close_rounded),
                      label: const Text(
                        'Close app',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
