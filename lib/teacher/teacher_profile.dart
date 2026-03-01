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

  final _auth = FirebaseAuth.instance;

  final _formKey = GlobalKey<FormState>();

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

  // Password rule: 8+ and at least 1 special character
  static final RegExp _specialRegex =
  RegExp(r'[!@#$%^&*(),.?":{}|<>_\-+=/\\\[\]~`]');

  @override
  void initState() {
    super.initState();
    _loadProfile();
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

  Future<void> _loadProfile() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });

    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not logged in.');

      _userRef = FirebaseDatabase.instance.ref('users/${user.uid}');
      final snap = await _userRef!.get();

      if (!snap.exists || snap.value == null) {
        throw Exception('No user record found in database.');
      }

      final data = Map<String, dynamic>.from(snap.value as Map);

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

    _formKey.currentState?.validate();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();

    setState(() {
      _error = null;
      _ok = null;
    });

    if (!_formKey.currentState!.validate()) return;

    setState(() => _busy = true);

    try {
      final user = _auth.currentUser;
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

      if (mounted) setState(() => _ok = 'Saved ✅');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------
  // Password change
  // ---------------------------

  String? _newPasswordValidator(String? v) {
    final value = (v ?? '').trim();
    if (value.isEmpty) return 'Password is required';
    if (value.length < 8) return 'Must be at least 8 characters';
    if (!_specialRegex.hasMatch(value)) return 'Add at least 1 special character';
    return null;
  }

  Future<bool> _confirmDialog({
    required String title,
    required String message,
    required String confirmText,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: actionOrange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _showChangePasswordSheet() async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You must be logged in.')),
      );
      return;
    }

    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final sheetKey = GlobalKey<FormState>();

    bool obscureCurrent = true;
    bool obscureNew = true;
    bool obscureConfirm = true;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final viewInsets = MediaQuery.of(ctx).viewInsets.bottom;
            final bottomSafe = MediaQuery.of(ctx).viewPadding.bottom;

            Future<void> submit() async {
              FocusScope.of(ctx).unfocus();
              if (!(sheetKey.currentState?.validate() ?? false)) return;

              final ok = await _confirmDialog(
                title: 'Confirm password change',
                message: 'Do you want to update your password now?',
                confirmText: 'Yes, change',
              );
              if (!ok) return;

              if (!mounted) return;
              setState(() => _busy = true);

              try {
                final email = currentUser.email;
                if (email == null || email.isEmpty) {
                  throw Exception('No email found for this account.');
                }

                final cred = EmailAuthProvider.credential(
                  email: email,
                  password: currentCtrl.text,
                );

                await currentUser.reauthenticateWithCredential(cred);
                await currentUser.updatePassword(newCtrl.text.trim());

                if (!mounted) return;
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Password updated ✅')),
                );
              } on FirebaseAuthException catch (e) {
                String msg = e.message ?? 'Failed to update password.';
                if (e.code == 'wrong-password') msg = 'Current password is incorrect.';
                if (e.code == 'requires-recent-login') {
                  msg = 'Please log in again, then retry changing your password.';
                }
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(msg)),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(e.toString())),
                  );
                }
              } finally {
                if (mounted) setState(() => _busy = false);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 12,
                bottom: 16 + bottomSafe + viewInsets,
              ),
              child: SingleChildScrollView(
                child: Form(
                  key: sheetKey,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Change Password',
                        style: TextStyle(
                          color: primaryBlue,
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Min 8 characters + at least 1 special character.',
                        style: TextStyle(
                          color: mainText.withOpacity(0.7),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 14),

                      _pwField(
                        label: 'Current password',
                        controller: currentCtrl,
                        obscure: obscureCurrent,
                        onToggle: () => setModalState(() => obscureCurrent = !obscureCurrent),
                        validator: (v) => (v ?? '').isEmpty ? 'Current password is required' : null,
                        onChanged: (_) => sheetKey.currentState?.validate(),
                      ),
                      const SizedBox(height: 10),

                      _pwField(
                        label: 'New password',
                        controller: newCtrl,
                        obscure: obscureNew,
                        onToggle: () => setModalState(() => obscureNew = !obscureNew),
                        validator: _newPasswordValidator,
                        onChanged: (_) => sheetKey.currentState?.validate(),
                      ),
                      const SizedBox(height: 10),

                      _pwField(
                        label: 'Confirm new password',
                        controller: confirmCtrl,
                        obscure: obscureConfirm,
                        onToggle: () => setModalState(() => obscureConfirm = !obscureConfirm),
                        validator: (v) {
                          final value = (v ?? '').trim();
                          if (value.isEmpty) return 'Please confirm your new password';
                          if (value != newCtrl.text.trim()) return 'Passwords do not match';
                          return null;
                        },
                        onChanged: (_) => sheetKey.currentState?.validate(),
                      ),

                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: const Icon(Icons.lock_reset_rounded),
                          label: const Text('Update password'),
                          style: FilledButton.styleFrom(
                            backgroundColor: actionOrange,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: _busy ? null : submit,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ---------------------------
  // UI helpers
  // ---------------------------

  InputDecoration _dec(
      String label, {
        Widget? suffixIcon,
        String? hintText,
      }) {
    return InputDecoration(
      labelText: label,
      hintText: hintText,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: uiBorder.withOpacity(0.9)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: primaryBlue, width: 1.6),
      ),
      suffixIcon: suffixIcon,
    );
  }

  Widget _pwField({
    required String label,
    required TextEditingController controller,
    required bool obscure,
    required VoidCallback onToggle,
    required String? Function(String?) validator,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: mainText.withOpacity(0.75),
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          obscureText: obscure,
          validator: validator,
          onChanged: onChanged,
          decoration: _dec(
            '',
            suffixIcon: IconButton(
              tooltip: obscure ? 'Show' : 'Hide',
              icon: Icon(
                obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                color: primaryBlue,
              ),
              onPressed: onToggle,
            ),
          ),
        ),
      ],
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

  // ---------------------------
  // Build
  // ---------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Teacher Profile',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: actionOrange),
            onPressed: _busy ? null : _loadProfile,
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
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

            // ✅ Scrollable + responsive (no overflow, works with big fonts/keyboard)
            LayoutBuilder(
              builder: (ctx, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Form(
                        key: _formKey,
                        autovalidateMode: AutovalidateMode.onUserInteraction,
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
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (_busy) const LinearProgressIndicator(),
                                const SizedBox(height: 12),

                                const Text(
                                  'Account',
                                  style: TextStyle(
                                    color: primaryBlue,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                _infoRow('Email', _emailReadOnly),
                                _infoRow('Role', _roleReadOnly),
                                _infoRow('Status', _statusReadOnly),

                                const SizedBox(height: 10),
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.lock_outline_rounded),
                                  label: const Text('Change password'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: primaryBlue,
                                    side: BorderSide(color: uiBorder.withOpacity(0.9)),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                  ),
                                  onPressed: _busy ? null : _showChangePasswordSheet,
                                ),

                                const SizedBox(height: 14),
                                const Divider(),
                                const SizedBox(height: 14),

                                const Text(
                                  'Edit Information',
                                  style: TextStyle(
                                    color: primaryBlue,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 12),

                                TextFormField(
                                  controller: _firstNameCtrl,
                                  decoration: _dec('First name'),
                                  onChanged: (_) => _formKey.currentState?.validate(),
                                  validator: (v) => (v ?? '').trim().isEmpty
                                      ? 'First name is required'
                                      : null,
                                ),
                                const SizedBox(height: 12),

                                TextFormField(
                                  controller: _lastNameCtrl,
                                  decoration: _dec('Last name'),
                                  onChanged: (_) => _formKey.currentState?.validate(),
                                  validator: (v) => (v ?? '').trim().isEmpty
                                      ? 'Last name is required'
                                      : null,
                                ),
                                const SizedBox(height: 12),

                                TextFormField(
                                  controller: _phone1Ctrl,
                                  keyboardType: TextInputType.phone,
                                  decoration: _dec('Phone 1'),
                                  onChanged: (_) => _formKey.currentState?.validate(),
                                ),
                                const SizedBox(height: 12),

                                TextFormField(
                                  controller: _phone2Ctrl,
                                  keyboardType: TextInputType.phone,
                                  decoration: _dec('Phone 2'),
                                  onChanged: (_) => _formKey.currentState?.validate(),
                                ),
                                const SizedBox(height: 12),

                                TextFormField(
                                  controller: _dobCtrl,
                                  readOnly: true,
                                  decoration: _dec(
                                    'Date of birth (YYYY-MM-DD)',
                                    hintText: 'e.g. 1994-01-12',
                                    suffixIcon: IconButton(
                                      icon: const Icon(Icons.calendar_month_rounded, color: primaryBlue),
                                      onPressed: _busy ? null : _pickDob,
                                    ),
                                  ),
                                  onTap: _busy ? null : _pickDob,
                                  validator: (v) {
                                    final value = (v ?? '').trim();
                                    if (value.isEmpty) return null; // optional
                                    final ok = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value);
                                    if (!ok) return 'Use YYYY-MM-DD format';
                                    return null;
                                  },
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

                                FilledButton(
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
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
