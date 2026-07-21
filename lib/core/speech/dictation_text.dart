import 'dart:math' as math;

/// Collapses repeated tokens like "hello hello hello" → "hello", which
/// cloud STT sometimes emits across partial updates.
String dedupeConsecutiveWords(String input) {
  final parts = input.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty) {
    return '';
  }
  final out = <String>[];
  for (final w in parts) {
    if (w.isEmpty) {
      continue;
    }
    if (out.isNotEmpty && out.last.toLowerCase() == w.toLowerCase()) {
      continue;
    }
    out.add(w);
  }
  return out.join(' ');
}

/// Joins text already committed from earlier listen segments with the latest
/// hypothesis. Handles (a) normal growth where [live] extends [prior], and
/// (b) OS session restarts where [live] begins again and would duplicate [prior].
String mergeDictationHypothesis(String priorCommitted, String liveHypothesis) {
  final a = priorCommitted.trim();
  final b = liveHypothesis.trim();
  if (b.isEmpty) {
    return a;
  }
  if (a.isEmpty) {
    return b;
  }
  final al = a.toLowerCase();
  final bl = b.toLowerCase();
  if (bl.startsWith(al)) {
    return b;
  }
  if (al.startsWith(bl)) {
    return a;
  }
  final maxCheck = math.min(a.length, b.length);
  for (var i = maxCheck; i > 0; i--) {
    if (al.endsWith(bl.substring(0, i))) {
      final tail = b.substring(i).trimLeft();
      if (tail.isEmpty) {
        return a;
      }
      return ('$a $tail').replaceAll(RegExp(r'\s+'), ' ').trim();
    }
  }
  return ('$a $b').replaceAll(RegExp(r'\s+'), ' ').trim();
}
