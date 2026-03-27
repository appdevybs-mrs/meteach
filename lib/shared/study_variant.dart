String normalizeVariantKey(String raw, {String fallback = 'inclass'}) {
  final v = raw.trim().toLowerCase();
  switch (v) {
    case 'inclass':
    case 'in-class':
    case 'in class':
    case 'in_class':
    case 'class':
      return 'inclass';
    case 'flexible':
    case 'online':
      return 'flexible';
    case 'private':
    case 'live':
    case 'vip':
      return 'private';
    case 'recorded':
    case 'record':
      return 'recorded';
    default:
      return v.isEmpty ? fallback : v;
  }
}

String normalizeStudyMode(String raw, {String variantKey = ''}) {
  final variant = normalizeVariantKey(variantKey, fallback: '');
  if (variant == 'flexible') return 'online';
  if (variant == 'inclass') return 'inclass';
  if (variant == 'recorded') return '';

  final v = raw.trim().toLowerCase();
  switch (v) {
    case 'inclass':
    case 'in_class':
    case 'in-class':
    case 'in class':
      return 'inclass';
    case 'online':
      return 'online';
    default:
      return v;
  }
}

String variantLabel(String variantKey) {
  switch (normalizeVariantKey(variantKey)) {
    case 'inclass':
      return 'In-Class';
    case 'flexible':
      return 'Flexible';
    case 'private':
      return 'Private';
    case 'recorded':
      return 'Recorded';
    default:
      return variantKey.trim();
  }
}

String studyModeLabel(String studyMode) {
  switch (normalizeStudyMode(studyMode)) {
    case 'online':
      return 'Online';
    case 'inclass':
      return 'In-Class';
    default:
      return studyMode.trim();
  }
}

String variantLabelWithStudyMode({
  required String variantKey,
  required String studyMode,
}) {
  final v = normalizeVariantKey(variantKey);
  final sm = normalizeStudyMode(studyMode, variantKey: v);

  if (v == 'private') {
    if (sm == 'online') return 'Private Online';
    if (sm == 'inclass') return 'Private In-Class';
    return 'Private';
  }

  return variantLabel(v);
}

String syllabusVariantForScheduledAttendance(String variantKey) {
  final v = normalizeVariantKey(variantKey);
  if (v == 'private') return 'private';
  return 'inclass';
}

String deliveryConfigKeyForVariant(String variantKey) {
  switch (normalizeVariantKey(variantKey)) {
    case 'flexible':
      return 'online';
    case 'private':
      return 'live';
    case 'recorded':
      return 'recorded';
    case 'inclass':
    default:
      return 'inclass';
  }
}

bool variantUsesAttendance(String variantKey) {
  final v = normalizeVariantKey(variantKey);
  return v == 'inclass' || v == 'private' || v == 'flexible';
}

bool variantIsScheduledClass(String variantKey) {
  final v = normalizeVariantKey(variantKey);
  return v == 'inclass' || v == 'private';
}

bool variantUsesExpiry(String variantKey) {
  final v = normalizeVariantKey(variantKey);
  return v == 'flexible' || v == 'recorded';
}
