import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../utils/reminder_context_parser.dart';
import '../utils/reminder_scheduling.dart';

class ReminderItem {
  const ReminderItem({
    required this.id,
    required this.title,
    required this.description,
    required this.client,
    required this.type,
    required this.message,
    required this.scheduledTimeMs,
    required this.dueDateMs,
    required this.status,
    required this.createdAtMs,
    this.relatedTaskId,
    this.priority = 'medium',
    this.isFollowUp = false,
    this.amount,
    this.rawInput,
    this.action,
    this.subType,
  });

  final String id;
  final String title;
  final String description;
  final String client;
  /// Firestore `type` (possibly inferred for legacy docs).
  final String type;
  final String message;
  /// Original user text when the reminder was created; used to re-hydrate display.
  final String? rawInput;
  final String? action;
  final int scheduledTimeMs;
  final int dueDateMs;
  final String status;
  final int createdAtMs;
  final String? relatedTaskId;
  final String priority;
  final bool isFollowUp;
  final double? amount;
  /// Full flow id, e.g. `reminder_followup` (backward-safe classification).
  final String? subType;

  /// `type` corrected using [subType] when older rows used wrong `type`.
  String get effectiveDocType {
    final st = (subType ?? '').toLowerCase();
    if (st.contains('followup')) {
      return 'followup';
    }
    return type.toLowerCase();
  }

  bool get isTaskRow => effectiveDocType == 'task';

  /// Second line for reports / lists: `📅 30 Apr, ⏰ 11:00 AM`
  String get displayListScheduleLine {
    final loc = DateTime.fromMillisecondsSinceEpoch(scheduledTimeMs);
    final dPart = DateFormat('d MMM').format(loc);
    final tPart = DateFormat('hh:mm a').format(loc);
    return '📅 $dPart, ⏰ $tPart';
  }

  /// Third line for task rows with non-default priority.
  String? get displayTaskPriorityLine {
    if (!isTaskRow) {
      return null;
    }
    final p = priority.toLowerCase().trim();
    if (p.isEmpty || p == 'medium') {
      return null;
    }
    final label = '${p[0].toUpperCase()}${p.substring(1)}';
    return '⚡ $label';
  }

  /// Popup / notification body line: `Today at 11:00 AM`, `Tomorrow at …`, or `Mon 28 Apr at …`
  static String formatPopupScheduleLine(int scheduledTimeMs) {
    final loc = DateTime.fromMillisecondsSinceEpoch(scheduledTimeMs);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(loc.year, loc.month, loc.day);
    final timePart = DateFormat('h:mm a').format(loc);
    if (d == today) {
      return 'Today at $timePart';
    }
    if (d == today.add(const Duration(days: 1))) {
      return 'Tomorrow at $timePart';
    }
    return '${DateFormat('EEE d MMM').format(loc)} at $timePart';
  }

  /// Report / list emoji: 📞 calls, 🗓️ meetings, 📌 generic tasks — distinct so
  /// rows are not all the same clipboard when Firestore `type` is `task`.
  String get iconEmoji {
    final t = effectiveDocType;
    switch (t) {
      case 'payment':
      case 'payment_followup':
      case 'manual_payment':
        return '💰';
      case 'followup':
        return '🔁';
      case 'meeting':
        return '🗓️';
      case 'call':
        return '📞';
      default:
        break;
    }
    final st = (subType ?? '').toLowerCase();
    if (st.contains('meeting')) {
      return '🗓️';
    }
    final hinted = reminderIconEmojiHintFromTitles(
      title: title,
      description: description,
      message: message,
      rawInput: rawInput,
    );
    if (hinted != null) {
      return hinted;
    }
    switch (t) {
      case 'task':
        return '📌';
      case 'reminder':
        return '📞';
      default:
        return '📌';
    }
  }

  /// Clean single-line title for lists (no raw Hinglish sentence).
  String get displayTitle {
    return ReminderContextParser.hydrateForDisplay(
      title: title,
      description: description,
      message: message,
      type: type,
      client: client,
      rawInput: rawInput,
    ).title;
  }

  /// Second line: purpose / note (e.g. "Artwork discussion"); not the raw user sentence.
  String get displaySubtitle {
    return ReminderContextParser.hydrateForDisplay(
      title: title,
      description: description,
      message: message,
      type: type,
      client: client,
      rawInput: rawInput,
    ).description;
  }

  factory ReminderItem.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final scheduledTimeMs = ReminderScheduling.epochMsFromFirestoreMap(data);

    var typeFromDoc = ((data['type'] as String?)?.trim() ?? '');
    if (typeFromDoc.isEmpty) {
      typeFromDoc = 'task';
    }
    typeFromDoc = typeFromDoc.toLowerCase();

    final subTypeStr = ((data['subType'] as String?) ?? '').trim();

    var resolvedType = typeFromDoc;
    if (resolvedType == 'task' &&
        subTypeStr.toLowerCase().contains('followup')) {
      resolvedType = 'followup';
    }

    return ReminderItem(
      id: doc.id,
      title: data['title'] as String? ?? '',
      description: data['description'] as String? ?? data['note'] as String? ?? '',
      client: data['client'] as String? ??
          data['clientName'] as String? ??
          data['clientLabel'] as String? ??
          '',
      type: resolvedType,
      message: data['message'] as String? ?? '',
      scheduledTimeMs: scheduledTimeMs,
      dueDateMs: (data['dueDateMs'] as num?)?.toInt() ??
          scheduledTimeMs,
      status: data['status'] as String? ?? 'pending',
      createdAtMs: (data['createdAtMs'] as num?)?.toInt() ?? 0,
      relatedTaskId: data['relatedTaskId'] as String?,
      priority: data['priority'] as String? ?? 'medium',
      isFollowUp: data['isFollowUp'] as bool? ?? false,
      amount: (data['amount'] as num?)?.toDouble(),
      rawInput: (data['rawInput'] as String?)?.trim(),
      action: (data['action'] as String?)?.trim(),
      subType: subTypeStr.isEmpty ? null : subTypeStr,
    );
  }
}

/// Dashboard / reports reminder card: semantic title from Firestore type (not generic "Task").
String buildDisplayTitle(ReminderItem item) {
  final t = item.effectiveDocType;
  final noteOrTitle =
      item.description.trim().isNotEmpty ? item.description : item.title;

  if (t == 'followup') {
    return 'Follow-up with ${item.client} for $noteOrTitle';
  }
  if (t == 'reminder' || t == 'call') {
    return 'Call ${item.client} for ${item.description}';
  }
  if (t == 'task') {
    return item.title;
  }
  return item.title;
}

String formatReminderReportDate(ReminderItem item) {
  final loc = DateTime.fromMillisecondsSinceEpoch(item.scheduledTimeMs);
  return DateFormat('d MMM').format(loc);
}

String formatReminderReportTime(ReminderItem item) {
  final loc = DateTime.fromMillisecondsSinceEpoch(item.scheduledTimeMs);
  return DateFormat('hh:mm a').format(loc);
}

bool reminderReportShowsPriorityLine(ReminderItem item) {
  final p = item.priority.trim().toLowerCase();
  return p.isNotEmpty && p != 'medium';
}

/// When [type] is wrong or generic (`task`), infer from title / note so list icons
/// match how the user phrased the reminder (Call… / Meeting… / Task…).
String? reminderIconEmojiHintFromTitles({
  required String title,
  String description = '',
  String message = '',
  String? rawInput,
}) {
  String head(String s) => s.trim().toLowerCase();

  final h = head(title);
  if (h.startsWith('meeting with') || h.startsWith('meeting ')) {
    return '🗓️';
  }
  if (h.startsWith('call ')) {
    return '📞';
  }
  if (h.startsWith('task ')) {
    return '📌';
  }
  final fused = head('$title $description $message ${rawInput ?? ''}');
  if (RegExp(r'\bmeeting\s+with\b').hasMatch(fused)) {
    return '🗓️';
  }
  return null;
}
