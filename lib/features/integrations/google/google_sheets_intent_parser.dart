/// Comma-separated cells for one Sheets row.
class GoogleSheetsRowIntent {
  const GoogleSheetsRowIntent({required this.cells});

  final List<String> cells;
}

class GoogleSheetsIntentParser {
  GoogleSheetsIntentParser._();

  static final RegExp _lead = RegExp(
    r'^(?:google\s*)?(?:sheet|spreadsheet)\s+row\s*[:\-]\s*(.+)$',
    caseSensitive: false,
  );

  static bool looksLike(String t) {
    final s = t.trim();
    if (s.length < 12) {
      return false;
    }
    return _lead.hasMatch(s);
  }

  static GoogleSheetsRowIntent? tryParse(String raw) {
    final m = _lead.firstMatch(raw.trim());
    if (m == null || m.group(1) == null) {
      return null;
    }
    final tail = m.group(1)!.trim();
    if (tail.isEmpty) {
      return null;
    }
    final cells = tail
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (cells.isEmpty) {
      return null;
    }
    return GoogleSheetsRowIntent(cells: cells);
  }
}
