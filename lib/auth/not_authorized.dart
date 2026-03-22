import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class NotAuthorized extends StatelessWidget {
  final String? role;
  const NotAuthorized({super.key, this.role});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Access denied')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.block, size: 46),
              const SizedBox(height: 12),
              Text(
                'Not authorized.\nRole: ${role ?? "unknown"}',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () async => FirebaseAuth.instance.signOut(),
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
