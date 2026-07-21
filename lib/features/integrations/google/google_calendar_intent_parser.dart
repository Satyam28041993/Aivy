import '../../reminders/utils/reminder_time_parser.dart';

/// Parsed line for [GoogleCalendarClient.insertTimedEvent].
class GoogleCalendarQuickAdd {
  const GoogleCalendarQuickAdd({
    required this.summary,
    required this.start,
    this.duration = const Duration(hours: 1),
  });

  final String summary;
  final DateTime start;
  final Duration duration;
}

/// Detects short chat lines that should create a Google Calendar event.
class GoogleCalendarIntentParser {
  GoogleCalendarIntentParser._();

  static final RegExp _keyword = RegExp(
    r'\b(calendar|kalender|meeting|event|schedule|कैलेंडर|मीटिंग)\b',
    caseSensitive: false,
  );

  static final RegExp _timeHint = RegExp(
    r'\b(aaj|kal|parso|tomorrow|today|baje|बजे|pm|am|\d{1,2}:\d{2}|\d{1,2}\s*\.\s*\d{2})\b',
    caseSensitive: false,
  );

  static bool looksLike(String t) {
    final s = t.trim();
    if (s.length < 8) {
      return false;
    }
    return _keyword.hasMatch(s) && _timeHint.hasMatch(s);
  }

  static GoogleCalendarQuickAdd? tryParse(String raw) {
    if (!looksLike(raw)) {
      return null;
    }
    final start = ReminderTimeParser.resolveScheduledTimeFromPlainText(raw);
    if (start == null) {
      return null;
    }
    final summary = _extractTitle(raw);
    return GoogleCalendarQuickAdd(
      summary: summary.isEmpty ? 'Meeting' : summary,
      start: start,
    );
  }

  static String _extractTitle(String raw) {
    var s = raw;
    for (final re in _stripPatterns) {
      s = s.replaceAll(RegExp(re, caseSensitive: false), ' ');
    }
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.length > 120) {
      s = s.substring(0, 120).trim();
    }
    if (s.length >= 3) {
      return s;
    }
    var fallback = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (fallback.length > 80) {
      fallback = fallback.substring(0, 80).trim();
    }
    return fallback.isEmpty ? 'Meeting' : fallback;
  }

  static const List<String> _stripPatterns = <String>[
    r'\b(calendar|kalender|meeting|event|schedule|कैलेंडर|मीटिंग)\b',
    r'\b(aaj|kal|parso|tomorrow|today)\b',
    r'\b(subah|dopahar|sham|सुबह|दोपहर|शाम)\b',
    r'\b(baje|बजे)\b',
    r'\b(am|pm)\b',
    r'\d{1,2}:\d{2}',
    r'\d{1,2}\s*\.\s*\d{2}',
    r'\d{1,2}\s*(am|pm)\b',
    r'[:\-–—,;]+',
    r'\b(add|lagao|likho|डालो|लगाओ|लिखो)\b',
    r'\b(google|गूगल)\b',
  ];
}
