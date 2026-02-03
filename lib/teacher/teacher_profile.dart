import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class TeacherProfileScreen extends StatefulWidget {
  const TeacherProfileScreen({super.key});

  @override
  State<TeacherProfileScreen> createState() => _TeacherProfileScreenState();
}

class _TeacherProfileScreenState extends State<TeacherProfileScreen> {
  // ===== Brand colors (same as AdminHome) =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _phone1Ctrl = TextEditingController();
  final _phone2Ctrl = TextEditingController();
  final _dobCtrl = TextEditingController();

  bool _busy = false;
  String? _error;
  String? _ok;

  String _emailReadOnly = '';
  String _roleReadOnly = '';
  String _statusReadOnly = '';

  DatabaseReference? _userRef;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('Not logged in.');
      }

      _userRef = FirebaseDatabase.instance.ref('users/${user.uid}');
      final snap = await _userRef!.get();

      if (!snap.exists) {
        throw Exception('No user record found in database.');
      }

      final data = (snap.value as Map?) ?? {};

      _firstNameCtrl.text = (data['first_name'] ?? '').toString();
      _lastNameCtrl.text = (data['last_name'] ?? '').toString();
      _phone1Ctrl.text = (data['phone1'] ?? '').toString();
      _phone2Ctrl.text = (data['phone2'] ?? '').toString();
      _dobCtrl.text = (data['dob'] ?? '').toString();

      _emailReadOnly = (data['email'] ?? user.email ?? '').toString();
      _roleReadOnly = (data['role'] ?? '').toString();
      _statusReadOnly = (data['status'] ?? '').toString();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickDob() async {
    // If dob already has value like 1994-01-12, parse it
    DateTime initial = DateTime(2000, 1, 1);
    try {
      final t = _dobCtrl.text.trim();
      if (t.isNotEmpty) {
        final parts = t.split('-');
        if (parts.length == 3) {
          initial = DateTime(
            int.parse(parts[0]),
            int.parse(parts[1]),
            int.parse(parts[2]),
          );
        }
      }
    } catch (_) {}

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1940, 1, 1),
      lastDate: DateTime.now(),
    );

    if (picked == null) return;

    final yyyy = picked.year.toString().padLeft(4, '0');
    final mm = picked.month.toString().padLeft(2, '0');
    final dd = picked.day.toString().padLeft(2, '0');
    _dobCtrl.text = '$yyyy-$mm-$dd';
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in.');

      final ref = FirebaseDatabase.instance.ref('users/${user.uid}');

      await ref.update({
        'first_name': _firstNameCtrl.text.trim(),
        'last_name': _lastNameCtrl.text.trim(),
        'phone1': _phone1Ctrl.text.trim(),
        'phone2': _phone2Ctrl.text.trim(),
        'dob': _dobCtrl.text.trim(),
        'updatedAt': ServerValue.timestamp,
      });

      _ok = 'Saved ✅';
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _phone1Ctrl.dispose();
    _phone2Ctrl.dispose();
    _dobCtrl.dispose();
    super.dispose();
  }

  InputDecoration _dec(String label, {Widget? suffixIcon}) {
    return InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: uiBorder.withOpacity(0.9)),
      ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: primaryBlue, width: 1.6),
      ),
      suffixIcon: suffixIcon,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Teacher Profile',
          style: TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: Stack(
        children: [
          Container(color: appBg),
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.05,
                child: Center(
                  child: FractionallySizedBox(
                    widthFactor: 0.75,
                    child: Image.asset(
                      'assets/images/ybs_logo.png',
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Card(
                  elevation: 0,
                  color: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: BorderSide(color: uiBorder.withOpacity(0.8)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_busy) const LinearProgressIndicator(),

                        const SizedBox(height: 12),

                        // Read-only info
                        _infoRow('Email', _emailReadOnly),
                        _infoRow('Role', _roleReadOnly),
                        _infoRow('Status', _statusReadOnly),

                        const SizedBox(height: 14),
                        const Divider(),
                        const SizedBox(height: 14),

                        TextField(
                          controller: _firstNameCtrl,
                          decoration: _dec('First name'),
                        ),
                        const SizedBox(height: 12),

                        TextField(
                          controller: _lastNameCtrl,
                          decoration: _dec('Last name'),
                        ),
                        const SizedBox(height: 12),

                        TextField(
                          controller: _phone1Ctrl,
                          keyboardType: TextInputType.phone,
                          decoration: _dec('Phone 1'),
                        ),
                        const SizedBox(height: 12),

                        TextField(
                          controller: _phone2Ctrl,
                          keyboardType: TextInputType.phone,
                          decoration: _dec('Phone 2'),
                        ),
                        const SizedBox(height: 12),

                        TextField(
                          controller: _dobCtrl,
                          readOnly: true,
                          decoration: _dec(
                            'Date of birth (YYYY-MM-DD)',
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.calendar_month_rounded,
                                  color: primaryBlue),
                              onPressed: _busy ? null : _pickDob,
                            ),
                          ),
                          onTap: _busy ? null : _pickDob,
                        ),

                        const SizedBox(height: 14),

                        if (_error != null) ...[
                          Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],

                        if (_ok != null) ...[
                          Text(
                            _ok!,
                            style: const TextStyle(
                              color: primaryBlue,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],

                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: actionOrange,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            onPressed: _busy ? null : _save,
                            child: Text(_busy ? 'Saving...' : 'Save'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: mainText.withOpacity(0.7),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              style: const TextStyle(
                color: mainText,
                fontWeight: FontWeight.w900,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
