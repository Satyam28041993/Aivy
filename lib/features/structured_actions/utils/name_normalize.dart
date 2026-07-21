/// Part 5: stable matching key for [structured_actions] — lowercase, no filler particles.
const Set<String> kNameStopParticles = {
  'se',
  'ka',
  'ki',
  'ke',
  'k',
  'ko',
  'mr',
  'mrs',
  'ms',
  'shri',
  'sri',
  'from',
  'the',
  'a',
  'an',
  'wala',
  'wali',
};

/// Lowercase, trim, remove common particles (whole-token), collapse spaces.
String normalizeName(String? raw) {
  if (raw == null) {
    return '';
  }
  var s = raw.toLowerCase().trim();
  if (s.isEmpty) {
    return '';
  }
  final parts = s.split(RegExp(r'\s+'));
  final out = <String>[];
  for (final p in parts) {
    final t = p.replaceAll(RegExp(r'^[.,!]+|[.,!]+$'), '');
    if (t.isEmpty) {
      continue;
    }
    if (kNameStopParticles.contains(t)) {
      continue;
    }
    out.add(t);
  }
  return out.join(' ').trim();
}
