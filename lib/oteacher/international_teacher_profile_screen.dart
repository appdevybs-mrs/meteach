import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

class InternationalTeacherProfileScreen extends StatefulWidget {
  const InternationalTeacherProfileScreen({super.key, required this.uid});
  final String uid;

  @override
  State<InternationalTeacherProfileScreen> createState() =>
      _InternationalTeacherProfileScreenState();
}

class _InternationalTeacherProfileScreenState
    extends State<InternationalTeacherProfileScreen> {
  final _db = FirebaseDatabase.instance.ref();
  final _photoC = TextEditingController();
  final _socialC = TextEditingController();
  final _passC = TextEditingController();
  bool _saving = false;
  String _subText = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _photoC.dispose();
    _socialC.dispose();
    _passC.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final snaps = await Future.wait([
      _db.child('users/${widget.uid}').get(),
      _db.child('international_teacher_profile/${widget.uid}').get(),
      _db.child('international_teacher_subscription/${widget.uid}').get(),
    ]);
    final u = _asMap(snaps[0].value);
    final p = _asMap(snaps[1].value);
    final s = _asMap(snaps[2].value);
    _photoC.text = (u['profile_photo'] ?? '').toString().trim();
    _socialC.text = (p['socialLinks'] ?? '').toString().trim();
    final expiresOn = (s['expiresOn'] ?? '').toString().trim();
    final amount = (s['amountPaidUsd'] ?? '').toString().trim();
    _subText = expiresOn.isEmpty
        ? 'Subscription not set'
        : 'Subscription: USD ${amount.isEmpty ? '-' : amount} • Expires: $expiresOn';
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _db.child('users/${widget.uid}').update({
        'profile_photo': _photoC.text.trim(),
        'updatedAt': ServerValue.timestamp,
      });
      await _db.child('international_teacher_profile/${widget.uid}').update({
        'socialLinks': _socialC.text.trim(),
        'updatedAt': ServerValue.timestamp,
      });

      final newPass = _passC.text.trim();
      if (newPass.isNotEmpty) {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null && user.uid == widget.uid) {
          await user.updatePassword(newPass);
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile updated.')));
      _passC.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Update failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Profile Photo URL',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _photoC,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'https://...',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Social Links',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _socialC,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Instagram: ...\nLinkedIn: ...',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passC,
                    obscureText: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Change Password',
                    ),
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.workspace_premium_outlined),
              title: const Text('Subscription'),
              subtitle: Text(_subText),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving...' : 'Save'),
          ),
        ],
      ),
    );
  }

  Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }
}
