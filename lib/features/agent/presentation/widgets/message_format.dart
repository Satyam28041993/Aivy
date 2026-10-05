// The little markdown Aivy's replies carry, turned into something a plain
// text widget can show.
//
// The model writes `**T6000e**` for emphasis and the bubble printed the
// asterisks as they were — a recommendation for a client read as
// "**TSC Printronix T6000e with ODV-2D**". Only bold is handled: it is the one
// mark the replies actually use, and a full markdown renderer would fight the
// bubble's own link and selection handling.

/// A run of reply text, bold or not.
class TextRun {
  const TextRun(this.text, {this.bold = false});

  final String text;
  final bool bold;

  @override
  bool operator ==(Object other) =>
      other is TextRun && other.text == text && other.bold == bold;

  @override
  int get hashCode => Object.hash(text, bold);

  @override
  String toString() => bold ? '**$text**' : text;
}

final RegExp _bold = RegExp(r'\*\*(.+?)\*\*', dotAll: true);

/// Splits text at `**bold**` marks. An unmatched `**` is left as written
/// rather than swallowing the rest of the message.
List<TextRun> boldRuns(String text) {
  final runs = <TextRun>[];
  var at = 0;
  for (final m in _bold.allMatches(text)) {
    if (m.start > at) {
      runs.add(TextRun(text.substring(at, m.start)));
    }
    runs.add(TextRun(m.group(1)!, bold: true));
    at = m.end;
  }
  if (at < text.length) {
    runs.add(TextRun(text.substring(at)));
  }
  return runs;
}

/// The text with its bold marks removed, for places that show plain text.
String stripBold(String text) =>
    text.replaceAllMapped(_bold, (m) => m.group(1)!);
