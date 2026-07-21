/// Shared gate before chat-created reminders hit Firestore.
class ReminderSaveValidator {
  ReminderSaveValidator._();

  /// Returns `null` when valid; otherwise a single-line message for the user.
  static String? validateWrite({
    required String title,
    required DateTime scheduledAt,
    String? clientName,
    bool requireClientName = false,
  }) {
    if (title.trim().isEmpty) {
      return 'Reminder title is required.';
    }
    if (requireClientName &&
        (clientName == null || clientName.trim().isEmpty)) {
      return 'Call reminder requires a client name.';
    }
    return null;
  }
}
