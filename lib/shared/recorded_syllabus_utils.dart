Map<String, dynamic> asStringKeyMap(dynamic node) {
  if (node is! Map) return <String, dynamic>{};
  final out = <String, dynamic>{};
  node.forEach((k, v) => out[k.toString()] = v);
  return out;
}

List<Map<String, dynamic>> asListOfMaps(dynamic node) {
  final out = <Map<String, dynamic>>[];

  if (node is List) {
    for (final item in node) {
      if (item is Map) out.add(asStringKeyMap(item));
    }
    return out;
  }

  if (node is Map) {
    final mm = Map<dynamic, dynamic>.from(node);
    for (final entry in mm.entries) {
      final value = entry.value;
      if (value is Map) out.add(asStringKeyMap(value));
    }
  }

  return out;
}

List<Map<String, dynamic>> flattenRecordedLessonsFromVariant(
  Map<String, dynamic> recordedVariant,
) {
  final out = <Map<String, dynamic>>[];
  final rawModules = asListOfMaps(recordedVariant['modules']);

  if (rawModules.isNotEmpty) {
    for (int mi = 0; mi < rawModules.length; mi++) {
      final module = rawModules[mi];
      final moduleOrder = _toInt(module['order'], fallback: mi + 1);
      final moduleTitle = (module['title'] ?? '').toString();
      final moduleOtherTitle = (module['otherTitle'] ?? '').toString();
      final units = asListOfMaps(module['units']);

      for (int ui = 0; ui < units.length; ui++) {
        final unit = units[ui];
        final unitOrder = _toInt(unit['order'], fallback: ui + 1);
        final unitTitle = (unit['title'] ?? '').toString();
        final unitOtherTitle = (unit['otherTitle'] ?? '').toString();
        final lessons = asListOfMaps(unit['lessons']);

        for (final lesson in lessons) {
          out.add({
            'moduleOrder': moduleOrder,
            'moduleTitle': moduleTitle,
            'moduleOtherTitle': moduleOtherTitle,
            'unitOrder': unitOrder,
            'unitTitle': unitTitle,
            'unitOtherTitle': unitOtherTitle,
            ...lesson,
          });
        }
      }
    }
    return out;
  }

  final legacyUnits = asListOfMaps(recordedVariant['units']);
  for (int ui = 0; ui < legacyUnits.length; ui++) {
    final unit = legacyUnits[ui];
    final unitOrder = _toInt(unit['order'], fallback: ui + 1);
    final unitTitle = (unit['title'] ?? '').toString();
    final unitOtherTitle = (unit['otherTitle'] ?? '').toString();
    final sessions = asListOfMaps(unit['sessions']);
    for (final session in sessions) {
      out.add({
        'moduleOrder': ui + 1,
        'moduleTitle': unitOtherTitle,
        'moduleOtherTitle': unitOtherTitle,
        'unitOrder': unitOrder,
        'unitTitle': unitTitle,
        'unitOtherTitle': unitOtherTitle,
        ...session,
      });
    }
  }
  return out;
}

int toRecordedSessionOrder(Map<String, dynamic> item) {
  final sessionNumber = _toInt(item['sessionNumber']);
  if (sessionNumber > 0) return sessionNumber;
  return _toInt(item['order']);
}

int _toInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}
