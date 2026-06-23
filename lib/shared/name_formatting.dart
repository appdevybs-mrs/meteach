String normalizePersonNamePart(String value) {
  final cleaned = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (cleaned.isEmpty) return '';

  return cleaned
      .split(' ')
      .map(_normalizeNameWord)
      .where((part) => part.isNotEmpty)
      .join(' ');
}

String _normalizeNameWord(String value) {
  final buffer = StringBuffer();
  var capitalizeNext = true;

  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    if (char == '-' || char == "'") {
      buffer.write(char);
      capitalizeNext = true;
      continue;
    }

    buffer.write(capitalizeNext ? char.toUpperCase() : char.toLowerCase());
    capitalizeNext = false;
  }

  return buffer.toString();
}
