import 'package:flutter/material.dart';

import 'profile_avatar.dart';

class ChatSenderIdentity {
  const ChatSenderIdentity({
    required this.uid,
    required this.displayName,
    required this.photoUrl,
  });

  final String uid;
  final String displayName;
  final String photoUrl;
}

String resolveDisplayNameFromUserMap(Map<dynamic, dynamic> raw, String uid) {
  final m = raw.map((k, v) => MapEntry(k.toString(), v));
  final first = (m['first_name'] ?? m['firstName'] ?? '').toString().trim();
  final last = (m['last_name'] ?? m['lastName'] ?? '').toString().trim();
  final full = ('$first $last').trim();
  if (full.isNotEmpty) return full;

  final fullName = (m['fullName'] ?? m['name'] ?? '').toString().trim();
  if (fullName.isNotEmpty) return fullName;

  final email = (m['email'] ?? '').toString().trim();
  if (email.isNotEmpty) return email;

  return uid.trim().isEmpty ? 'User' : uid.trim();
}

String resolvePhotoUrlFromUserMap(Map<dynamic, dynamic> raw) {
  return ProfileAvatar.resolvePhotoFromMap(raw);
}

Color senderAccentColor(String seed) {
  const palette = <Color>[
    Color(0xFF1F5C99),
    Color(0xFF2E7D6E),
    Color(0xFF8A5A1E),
    Color(0xFF7A3E70),
    Color(0xFF2D6A8E),
    Color(0xFF6E5D2B),
    Color(0xFF4F5FA8),
    Color(0xFF9A4D3A),
  ];
  final clean = seed.trim();
  final idx = (clean.isEmpty ? 0 : clean.hashCode.abs()) % palette.length;
  return palette[idx];
}
