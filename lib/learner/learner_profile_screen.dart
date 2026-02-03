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

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _usersRef = _db.child(usersNode);

  bool _busy = true;
  String? _error;

  String _uid = '';
  Map<String, dynamic> _user = {};

  final _fn = TextEditingController();
  final _ln = TextEditingController();
  final _phone1 = TextEditingController();
  final _phone2 = TextEditingController();
  final _dob = TextEditingController();

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
    setState(() {
      _busy = true;
      _error = null;
      _user = {};
      _uid = '';
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in.');
      _uid = user.uid;

      final snap = await _usersRef.child(_uid).get();
      if (!snap.exists || snap.value == null || snap.value is! Map) throw Exception('User record not found.');

      _user = Map<String, dynamic>.from(snap.value as Map);

      _fn.text = (_user['first_name'] ?? '').toString();
      _ln.text = (_user['last_name'] ?? '').toString();
      _phone1.text = (_user['phone1'] ?? '').toString();
      _phone2.text = (_user['phone2'] ?? '').toString();
      _dob.text = (_user['dob'] ?? '').toString();

      setState(() => _busy = false);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });

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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile updated ✅')));
      _load();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = (_user['email'] ?? '').toString();
    final serial = (_user['serial'] ?? '').toString();
    final role = (_user['role'] ?? '').toString();
    final status = (_user['status'] ?? '').toString();

    return Scaffold(
      backgroundColor: UiK.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: UiK.primaryBlue),
        title: const Text('My Profile', style: TextStyle(color: UiK.primaryBlue, fontWeight: FontWeight.w900)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: UiK.actionOrange),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: WatermarkBackground(
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
          ),
        )
            : ListView(
          padding: const EdgeInsets.all(16),
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
                    _field('First name', _fn),
                    const SizedBox(height: 10),
                    _field('Last name', _ln),
                    const SizedBox(height: 10),
                    _field('Phone 1', _phone1, keyboard: TextInputType.phone),
                    const SizedBox(height: 10),
                    _field('Phone 2', _phone2, keyboard: TextInputType.phone),
                    const SizedBox(height: 10),
                    _field('Date of birth (YYYY-MM-DD)', _dob),
                    const SizedBox(height: 14),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.save_rounded),
                      label: const Text('Save'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: UiK.actionOrange,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _save,
                    ),
                  ],
                ),
              ),
            ),
          ],
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
            width: 70,
            child: Text(label, style: TextStyle(color: UiK.mainText.withOpacity(0.7), fontWeight: FontWeight.w800)),
          ),
          Expanded(
            child: Text(value.isEmpty ? '-' : value, style: const TextStyle(color: UiK.mainText, fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );
  }

  Widget _field(String label, TextEditingController c, {TextInputType keyboard = TextInputType.text}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: UiK.mainText.withOpacity(0.75), fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        TextField(
          controller: c,
          keyboardType: keyboard,
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
          ),
        ),
      ],
    );
  }
}
