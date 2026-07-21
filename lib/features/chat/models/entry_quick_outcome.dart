/// Snapshot of an entry after command processing (for Home quick-response UI).
class EntryQuickOutcome {
  const EntryQuickOutcome({
    required this.assistantReply,
    required this.contextType,
    required this.memoryCategory,
    required this.reminderSuggestionCount,
  });

  final String assistantReply;
  final String contextType;
  final String memoryCategory;
  final int reminderSuggestionCount;

  static String shortenReply(String raw, {int maxChars = 220}) {
    final s = raw.trim();
    if (s.length <= maxChars) {
      return s;
    }
    return '${s.substring(0, maxChars - 1)}…';
  }

  /// Short status line derived from stored fields (no extra backend calls).
  static String? actionLine(EntryQuickOutcome o) {
    final ct = o.contextType.toLowerCase();
    final ar = o.assistantReply.toLowerCase();

    if (ct == 'local_quotation') {
      return 'Quotation saved';
    }
    if (ct == 'local_reminder') {
      if (ar.contains('follow-up')) {
        return 'Follow-up scheduled';
      }
      return 'Reminder scheduled';
    }
    if (ct == 'local_greeting') {
      return null;
    }
    if (ct == 'local_quotation_parse_failed') {
      return 'Could not save quotation';
    }
    if (ct.contains('duplicate')) {
      return 'Already exists';
    }
    if (ct == 'local_follow_up_no_quotation') {
      return 'No matching quotation';
    }

    final mc = o.memoryCategory.toLowerCase();
    if (mc == 'quotation') {
      return 'Quotation saved';
    }
    if (o.reminderSuggestionCount > 0) {
      if (o.reminderSuggestionCount == 1) {
        return 'Reminder created';
      }
      return '${o.reminderSuggestionCount} reminders created';
    }

    if (ct == 'local_intent') {
      return null;
    }

    return 'Saved to your log';
  }
}
