/// Maps [flowCategoryId] (e.g. `reminder_followup`) to Firestore `type` + full `subType`.
class ReminderDocClassification {
  const ReminderDocClassification({
    required this.type,
    required this.subType,
  });

  final String type;
  final String subType;
}

/// Classification rules (specific matches before generic `reminder_` prefix):
/// - `followup_*` → followup + full id
/// - `payment_*` → payment + full id (handled separately in callers)
/// - `reminder_task` / `task_*` → task
/// - `reminder_followup` / ids containing `followup` → followup
/// - other `reminder_*` → reminder + full id
ReminderDocClassification reminderDocClassificationFromFlowCategoryId(
  String flowCategoryId,
) {
  final f = flowCategoryId.trim();
  if (f.isEmpty) {
    return const ReminderDocClassification(
      type: 'reminder',
      subType: 'reminder_general',
    );
  }
  if (f.startsWith('followup_')) {
    return ReminderDocClassification(type: 'followup', subType: f);
  }
  if (f.startsWith('task_')) {
    return ReminderDocClassification(type: 'task', subType: f);
  }
  if (f == 'reminder_task') {
    return ReminderDocClassification(type: 'task', subType: f);
  }
  if (f == 'reminder_followup' || f.contains('followup')) {
    return ReminderDocClassification(type: 'followup', subType: f);
  }
  if (f.startsWith('payment_')) {
    return ReminderDocClassification(type: 'payment', subType: f);
  }
  if (f.startsWith('reminder_')) {
    return ReminderDocClassification(type: 'reminder', subType: f);
  }
  return ReminderDocClassification(type: 'reminder', subType: f);
}

/// When Firestore `type` is missing (legacy rows), infer from `subType` / flags.
String inferReminderDocTypeFallback(Map<String, dynamic> data) {
  final st = (data['subType'] as String? ?? '').toLowerCase();
  if (st.contains('followup')) {
    return 'followup';
  }
  if (st.contains('task')) {
    return 'task';
  }
  if (st.contains('call') || st.contains('meeting')) {
    return 'reminder';
  }
  if (st.startsWith('payment')) {
    return 'payment';
  }
  return 'reminder';
}
