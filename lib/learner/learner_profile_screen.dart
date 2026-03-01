import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';

class LearnerProfileScreen extends StatefulWidget {
  const LearnerProfileScreen({super.key});

  @override
  State<LearnerProfileScreen> createState() => _LearnerProfileScreenState();
}

class _LearnerProfileScreenState extends State<LearnerProfileScreen> {
  static const usersNode = 'users';

  final _auth = FirebaseAuth.instance;
  final DatabaseReference _usersRef =
  FirebaseDatabase.instance.ref().child(usersNode);

  final _formKey = GlobalKey<FormState>();

  bool _busy = false;
  String? _error;

  String _uid = '';
  Map<String, dynamic> _user = {};

  final _fn = TextEditingController();
  final _ln = TextEditingController();
  final _phone1 = TextEditingController();
  final _phone2 = TextEditingController();
  final _dob = TextEditingController();

  // Password rule: 8+ and at least 1 special character
  static final RegExp _specialRegex =
  RegExp(r'[!@#$%^&*(),.?":{}|<>_\-+=/\\\[\]~`]');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _fn.dispose();
    _ln.dispose();
    _phone1.dispose();
    _phone2.dispose();
    _dob.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _user = {};
      _uid = '';
    });

    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not logged in.');
      _uid = user.uid;

      final snap = await _usersRef.child(_uid).get();
      if (!snap.exists || snap.value == null || snap.value is! Map) {
        throw Exception('User record not found.');
      }

      _user = Map<String, dynamic>.from(snap.value as Map);

      _fn.text = (_user['first_name'] ?? '').toString();
      _ln.text = (_user['last_name'] ?? '').toString();
      _phone1.text = (_user['phone1'] ?? '').toString();
      _phone2.text = (_user['phone2'] ?? '').toString();
      _dob.text = (_user['dob'] ?? '').toString();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();

    setState(() {
      _error = null;
    });

    if (!_formKey.currentState!.validate()) return;

    setState(() => _busy = true);

    try {
      if (_uid.isEmpty) throw Exception('Missing uid');

      final updates = <String, dynamic>{
        'first_name': _fn.text.trim(),
        'last_name': _ln.text.trim(),
        'phone1': _phone1.text.trim(),
        'phone2': _phone2.text.trim(),
        'dob': _dob.text.trim(),
        'updatedAt': ServerValue.timestamp,
      };

      await _usersRef.child(_uid).update(updates);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated ✅')),
      );
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------
  // Password change UI/logic
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
              backgroundColor: UiK.actionOrange,
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

    // Keep controllers local and DO NOT manually dispose to avoid
    // "used after disposed" during hot reload / overlay transitions.
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
      useSafeArea: true, // ✅ protects from system UI
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final viewInsets = MediaQuery.of(ctx).viewInsets.bottom; // keyboard
            final bottomSafe = MediaQuery.of(ctx).viewPadding.bottom; // nav bar

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

                // Firebase requires recent login
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

            // ✅ Scrollable sheet content => no overflow on small screens / big fonts
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
                      Text('Change Password', style: UiK.titleText()),
                      const SizedBox(height: 10),
                      Text(
                        'Min 8 characters + at least 1 special character.',
                        style: TextStyle(
                          color: UiK.mainText.withOpacity(0.7),
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
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.lock_reset_rounded),
                          label: const Text('Update password'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: UiK.actionOrange,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
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
            color: UiK.mainText.withOpacity(0.75),
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          obscureText: obscure,
          validator: validator,
          onChanged: onChanged,
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: UiK.uiBorder.withOpacity(0.85)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: UiK.actionOrange, width: 1.2),
            ),
            suffixIcon: IconButton(
              tooltip: obscure ? 'Show' : 'Hide',
              onPressed: onToggle,
              icon: Icon(obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------
  // Main UI
  // ---------------------------

  @override
  Widget build(BuildContext context) {
    final email = (_user['email'] ?? '').toString();
    final serial = (_user['serial'] ?? '').toString();
    final role = (_user['role'] ?? '').toString();
    final status = (_user['status'] ?? '').toString();

    return Scaffold(
      backgroundColor: UiK.appBg,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: UiK.primaryBlue),
        title: const Text(
          'My Profile',
          style: TextStyle(color: UiK.primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: UiK.actionOrange),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: SafeArea(
        child: WatermarkBackground(
          child: _busy
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w800,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          )
              : Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: LayoutBuilder(
              builder: (ctx, constraints) {
                // ✅ Ensures the list can always scroll and won't overflow on short heights / big fonts
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Card(
                          elevation: 0,
                          color: Colors.white,
                          shape: UiK.cardShape(),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Account', style: UiK.titleText()),
                                const SizedBox(height: 10),
                                _readonlyRow('Email', email),
                                _readonlyRow('Serial', serial),
                                _readonlyRow('Role', role),
                                _readonlyRow('Status', status),
                                const SizedBox(height: 10),
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.lock_outline_rounded),
                                  label: const Text('Change password'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: UiK.primaryBlue,
                                    side: BorderSide(color: UiK.uiBorder.withOpacity(0.9)),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                  ),
                                  onPressed: _busy ? null : _showChangePasswordSheet,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Card(
                          elevation: 0,
                          color: Colors.white,
                          shape: UiK.cardShape(),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Edit Information', style: UiK.titleText()),
                                const SizedBox(height: 10),
                                _field(
                                  'First name',
                                  _fn,
                                  validator: (v) =>
                                  (v ?? '').trim().isEmpty ? 'First name is required' : null,
                                ),
                                const SizedBox(height: 10),
                                _field(
                                  'Last name',
                                  _ln,
                                  validator: (v) =>
                                  (v ?? '').trim().isEmpty ? 'Last name is required' : null,
                                ),
                                const SizedBox(height: 10),
                                _field('Phone 1', _phone1, keyboard: TextInputType.phone),
                                const SizedBox(height: 10),
                                _field('Phone 2', _phone2, keyboard: TextInputType.phone),
                                const SizedBox(height: 10),
                                _field(
                                  'Date of birth (YYYY-MM-DD)',
                                  _dob,
                                  hintText: 'e.g. 2000-01-31',
                                  validator: (v) {
                                    final value = (v ?? '').trim();
                                    if (value.isEmpty) return null; // optional
                                    final ok = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value);
                                    if (!ok) return 'Use YYYY-MM-DD format';
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 14),
                                ElevatedButton.icon(
                                  icon: const Icon(Icons.save_rounded),
                                  label: const Text('Save'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: UiK.actionOrange,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                  ),
                                  onPressed: _busy ? null : _save,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _readonlyRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(
                color: UiK.mainText.withOpacity(0.7),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(
      String label,
      TextEditingController c, {
        TextInputType keyboard = TextInputType.text,
        String? hintText,
        String? Function(String?)? validator,
      }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: UiK.mainText.withOpacity(0.75), fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: c,
          keyboardType: keyboard,
          validator: validator,
          onChanged: (_) => _formKey.currentState?.validate(),
          decoration: InputDecoration(
            hintText: hintText,
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: UiK.uiBorder.withOpacity(0.85)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: UiK.actionOrange, width: 1.2),
            ),
          ),
        ),
      ],
    );
  }
}
