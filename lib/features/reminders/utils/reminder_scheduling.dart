import 'package:cloud_firestore/cloud_firestore.dart';

/// Single scheduling pipeline for reminders.
///
/// **Canonical field:** [scheduledAt] (`Timestamp`, local instant).
/// **Derived cache:** [scheduledTimeMs] is written only at save time as
/// `scheduledAt.toDate().millisecondsSinceEpoch` so queries can use composite
/// indexes. On read, always prefer [scheduledAt]; use [epochMsFromFirestoreMap]
/// when resolving display / sorting.
class ReminderScheduling {
  ReminderScheduling._();

  /// Effective instant for a reminder document (local clock ms).
  /// Prefers [scheduledAt]; falls back to [scheduledTimeMs] for legacy rows.
  static int epochMsFromFirestoreMap(Map<String, dynamic> data) {
    final ts = data['scheduledAt'];
    if (ts is Timestamp) {
      return ts.millisecondsSinceEpoch;
    }
    final ms = (data['scheduledTimeMs'] as num?)?.toInt();
    if (ms != null && ms > 0) {
      return ms;
    }
    return 0;
  }

  /// Same as [epochMsFromFirestoreMap], exposed for typed snapshot data.
  static int epochMsFromData(Map<String, dynamic>? data) {
    if (data == null) {
      return 0;
    }
    return epochMsFromFirestoreMap(data);
  }

  /// Derived milliseconds — must match [scheduledAt] at write time.
  static int derivedScheduledTimeMs(DateTime scheduledLocal) {
    return scheduledLocal.toLocal().millisecondsSinceEpoch;
  }
}
