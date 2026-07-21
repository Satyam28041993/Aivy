import 'package:intl/intl.dart';

import '../../reminders/models/reminder_item.dart';
import '../../structured_actions/models/structured_action.dart';
import '../utils/aivy_response_formatter.dart';
import 'flow_catalog.dart';
import 'flow_step_engine.dart';

/// Time-based greeting + fixed honorific line for the category sheet intro.
String getGreeting() {
  final h = DateTime.now().hour;
  final prefix = h >= 5 && h < 12
      ? 'Good Morning'
      : h >= 12 && h < 17
          ? 'Good Afternoon'
          : h >= 17 && h < 22
              ? 'Good Evening'
              : 'Hello';
  return '$prefix Satyam Sir, aap kya karna chahte hai?';
}

/// Category-specific copy for the in-chat confirm card (no generic "Collect").
String formatConfirmSummary(
  Map<String, dynamic> data,
  StructuredAction draft,
) {
  final fcid =
      (data['flowCategoryId'] as String? ?? '').trim().isNotEmpty
          ? data['flowCategoryId'] as String
          : _inferFlowCategoryId(draft);
  if (fcid.startsWith('reminder_')) {
    return formatReminderSummary(data, draft);
  }
  if (fcid.startsWith('payment_')) {
    return formatPaymentSummary(draft, flowCategoryId: fcid);
  }
  if (fcid.startsWith('order_')) {
    return formatOrderStyleSummary(
      draft,
      title: 'Order',
      headVerb: 'Save',
    );
  }
  if (fcid == 'followup_client') {
    final name = draft.name.isEmpty ? '—' : draft.name;
    var dateLine = '—';
    if (draft.date != null) {
      dateLine = DateFormat('d MMM, hh:mm a').format(draft.date!.toLocal());
    }
    return [
      'Client Follow-up',
      '',
      'Client: $name',
      'Follow-up on: $dateLine',
      if (draft.note != null && draft.note!.trim().isNotEmpty)
        'Work: ${draft.note!.trim()}',
      '',
      '(Confirm / Edit / Cancel bhejein)',
    ].join('\n');
  }
  if (fcid == 'personal_task') {
    var whenLine = '—';
    if (draft.date != null) {
      whenLine = DateFormat('d MMM, hh:mm a').format(draft.date!.toLocal());
    }
    return [
      'Personal Reminder',
      '',
      'Task: ${draft.name.isEmpty ? '—' : draft.name}',
      'Remind on: $whenLine',
      if (draft.note != null && draft.note!.trim().isNotEmpty)
        'Note: ${draft.note!.trim()}',
      '',
      '(Confirm / Edit / Cancel bhejein)',
    ].join('\n');
  }
  if (fcid == 'personal_birthday') {
    return [
      'Birthday Tracker',
      '',
      'Name: ${draft.name.isEmpty ? '—' : draft.name}',
      'Birthday: ${(data[FlowStepEngine.kBirthDate] as String? ?? '—')}',
      if (draft.note != null && draft.note!.trim().isNotEmpty)
        'Note: ${draft.note!.trim()}',
      '',
      '(Confirm / Edit / Cancel bhejein)',
    ].join('\n');
  }
  if (fcid.startsWith('quotation_')) {
    if (fcid == 'quotation_new') {
      final name = draft.name.isEmpty ? '—' : draft.name;
      final cur = NumberFormat.currency(
        locale: 'en_IN',
        symbol: '₹',
        decimalDigits: 0,
      );
      final amt = draft.amount != null ? cur.format(draft.amount) : '—';
      var followUpLine = '—';
      if (draft.date != null) {
        followUpLine = DateFormat('d MMM, hh:mm a').format(draft.date!.toLocal());
      }
      return [
        'Quotation',
        '',
        'Save — $name',
        'Amount: $amt',
        'Follow-up on: $followUpLine',
        if (draft.note != null && draft.note!.trim().isNotEmpty)
          'Note: ${draft.note!.trim()}',
        '',
        '(Confirm / Edit / Cancel bhejein)',
      ].join('\n');
    }
    if (fcid == 'quotation_followup') {
      final name = draft.name.isEmpty ? '—' : draft.name;
      var dateLine = '—';
      if (draft.date != null) {
        dateLine = DateFormat('d MMM, hh:mm a').format(draft.date!.toLocal());
      }
      return [
        'Quotation Follow-up',
        '',
        'Client: $name',
        'Follow-up: $dateLine',
        if (draft.note != null && draft.note!.trim().isNotEmpty)
          'Note: ${draft.note!.trim()}',
        '',
        '(Confirm / Edit / Cancel bhejein)',
      ].join('\n');
    }
    return formatOrderStyleSummary(
      draft,
      title: 'Quotation',
      headVerb: 'Save',
    );
  }
  return formatGenericCrmSummary(draft, fcid: fcid);
}

String _inferFlowCategoryId(StructuredAction d) {
  return flowCategoryIdFromActionTypes(d.type, d.subType);
}

/// Human-readable reminder block for the in-chat confirm step.
String formatReminderSummary(
  Map<String, dynamic> data,
  StructuredAction draft,
) {
  final fcid = (data['flowCategoryId'] as String? ?? 'reminder_task').trim();
  if (fcid == 'reminder_task') {
    return _formatTaskReminderConfirmSummary(data, draft);
  }
  final isCall = fcid == 'reminder_call';
  final name = (data[FlowStepEngine.kName] as String? ?? draft.name).trim();
  final note = (data[FlowStepEngine.kNote] as String? ?? draft.note ?? '').trim();
  DateTime? day;
  final dr = data[FlowStepEngine.kDate] ?? data['date'];
  if (dr is num) {
    final t = DateTime.fromMillisecondsSinceEpoch(dr.toInt());
    day = DateTime(t.year, t.month, t.day);
  }
  if (day == null && draft.date != null) {
    final t = draft.date!.toLocal();
    day = DateTime(t.year, t.month, t.day);
  }
  final dStr = day != null ? DateFormat('d MMM yyyy').format(day) : '—';
  int? tmin = data[FlowStepEngine.kTime] is num
      ? (data[FlowStepEngine.kTime] as num).toInt()
      : null;
  final timeSkipped = data['timeSkipped'] == true;
  if (timeSkipped && dr is num) {
    final raw = DateTime.fromMillisecondsSinceEpoch(dr.toInt());
    final em = raw.hour * 60 + raw.minute;
    if (em != 0) {
      tmin = em;
    }
  }
  if (tmin == null && draft.date != null && dr is num) {
    final t = draft.date!.toLocal();
    tmin = t.hour * 60 + t.minute;
  }
  String timeStr = '—';
  if (tmin != null) {
    timeStr = DateFormat('hh:mm a').format(
      DateTime(2000, 1, 1, tmin ~/ 60, tmin % 60),
    );
  }
  final hasResolvedTimeMinutes = tmin != null;
  final hasDay = day != null;

  // Only offer Confirm copy when both calendar day and time minutes exist.
  final showConfirmFooter = hasDay && hasResolvedTimeMinutes;

  final head = isCall ? '📞 Call Reminder' : '✅ Task Reminder';
  final displayName = name.isNotEmpty ? capitalizeWords(name) : '';
  final displayNote = note.isNotEmpty ? capitalizeWords(note) : '';
  final clientLine = displayName.isNotEmpty ? '👤 Client: $displayName' : '👤 Client: —';
  return [
    head,
    '',
    clientLine,
    '🗓 Date: $dStr',
    '⏰ Time: $timeStr',
    '📝 Work: ${displayNote.isNotEmpty ? displayNote : '—'}',
    '',
    if (showConfirmFooter)
      '(Confirm / Edit / Cancel bhejein)'
    else
      '(Pehle date aur time poora karein — Confirm baad mein)',
  ].join('\n');
}

String _formatTaskReminderConfirmSummary(
  Map<String, dynamic> data,
  StructuredAction draft,
) {
  final taskRaw =
      (data[FlowStepEngine.kTaskTitle] as String? ?? data['taskTitle'] as String? ?? '')
          .trim();
  final taskLine =
      taskRaw.isNotEmpty ? capitalizeWords(taskRaw) : '—';
  final clientRaw = (data['clientName'] as String? ?? '').trim();
  final note =
      (data[FlowStepEngine.kNote] as String? ?? draft.note ?? '').trim();
  final pr = (data['priority'] as String? ?? 'Medium').toString().trim();

  DateTime? day;
  final dr = data[FlowStepEngine.kDate] ?? data['date'];
  if (dr is num) {
    final t = DateTime.fromMillisecondsSinceEpoch(dr.toInt());
    day = DateTime(t.year, t.month, t.day);
  }
  if (day == null && draft.date != null) {
    final t = draft.date!.toLocal();
    day = DateTime(t.year, t.month, t.day);
  }
  final dStr = day != null ? DateFormat('d MMM yyyy').format(day) : '—';

  int? tmin = data[FlowStepEngine.kTime] is num
      ? (data[FlowStepEngine.kTime] as num).toInt()
      : null;
  final timeSkipped = data['timeSkipped'] == true;
  if (timeSkipped && dr is num) {
    final raw = DateTime.fromMillisecondsSinceEpoch(dr.toInt());
    final em = raw.hour * 60 + raw.minute;
    if (em != 0) {
      tmin = em;
    }
  }
  if (tmin == null && draft.date != null && dr is num) {
    final t = draft.date!.toLocal();
    tmin = t.hour * 60 + t.minute;
  }
  var timeStr = '—';
  if (tmin != null) {
    timeStr = DateFormat('hh:mm a').format(
      DateTime(2000, 1, 1, tmin ~/ 60, tmin % 60),
    );
  }
  final hasResolvedTimeMinutes = tmin != null;
  final hasDay = day != null;
  final showConfirmFooter = hasDay && hasResolvedTimeMinutes;

  final lines = <String>[
    '✅ Task Reminder',
    '',
    '📝 Task: $taskLine',
    if (clientRaw.isNotEmpty)
      '👤 Client: ${capitalizeWords(clientRaw)}',
    '📅 Deadline: $dStr',
    '⏰ Time: $timeStr',
    '⚡ Priority: $pr',
    '🧾 Note: ${note.isNotEmpty ? capitalizeWords(note) : '—'}',
    '',
    if (showConfirmFooter)
      '(Confirm / Edit / Cancel bhejein)'
    else
      '(Pehle deadline aur time poora karein — Confirm baad mein)',
  ];
  return lines.join('\n');
}

String formatPaymentSummary(
  StructuredAction d, {
  required String flowCategoryId,
  String? titleOverride,
}) {
  final head = titleOverride?.trim().isNotEmpty == true
      ? titleOverride!.trim()
      : getConfirmTitleForCategory(flowCategoryId);
  final verb = getLabelByCategory(flowCategoryId);
  final cur = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );
  final name = d.name.isEmpty ? '—' : d.name;
  final amt = d.amount != null ? cur.format(d.amount) : '—';
  var dateLine = '—';
  if (d.date != null) {
    final t = d.date!.toLocal();
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      dateLine = 'Today';
    } else {
      dateLine = DateFormat('d MMM').format(t);
    }
  }
  return [
    head,
    '',
    '$verb $amt — $name',
    'Due / ref: $dateLine',
    if (d.note != null && d.note!.trim().isNotEmpty) 'Note: ${d.note!.trim()}',
    '',
    '(Confirm / Edit / Cancel bhejein)',
  ].join('\n');
}

String formatOrderStyleSummary(
  StructuredAction d, {
  required String title,
  required String headVerb,
}) {
  final name = d.name.isEmpty ? '—' : d.name;
  final cur = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );
  final amt = d.amount != null ? cur.format(d.amount) : '—';
  return [
    title,
    '',
    '$headVerb — $name',
    'Amount: $amt',
    if (d.note != null && d.note!.trim().isNotEmpty) 'Note: ${d.note!.trim()}',
    '',
    '(Confirm / Edit / Cancel bhejein)',
  ].join('\n');
}

String formatGenericCrmSummary(
  StructuredAction d, {
  required String fcid,
}) {
  return formatOrderStyleSummary(
    d,
    title: getConfirmTitleForCategory(fcid),
    headVerb: 'Save',
  );
}

String getConfirmTitleForCategory(String? flowCategoryId) {
  if (flowCategoryId == null || flowCategoryId.isEmpty) {
    return 'Confirm';
  }
  if (flowCategoryId.startsWith('reminder_')) {
    return flowCategoryId == 'reminder_call'
        ? 'Call Reminder'
        : 'Task Reminder';
  }
  if (flowCategoryId == 'payment_received') {
    return 'Payment received';
  }
  if (flowCategoryId == 'payment_due' || flowCategoryId == 'payment_followup') {
    return 'Payment follow-up';
  }
  if (flowCategoryId.startsWith('order_')) {
    return 'Order';
  }
  if (flowCategoryId.startsWith('quotation_')) {
    return 'Quotation';
  }
  return 'Confirm';
}

/// Primary CTA line verb for summaries (replaces wrong "Collect" on reminders).
String getLabelByCategory(String? flowCategoryId) {
  if (flowCategoryId == null || flowCategoryId.isEmpty) {
    return 'Confirm';
  }
  if (flowCategoryId.startsWith('reminder_')) {
    return 'Set reminder';
  }
  if (flowCategoryId == 'payment_due' ||
      flowCategoryId == 'payment_followup') {
    return 'Collect';
  }
  if (flowCategoryId == 'payment_received') {
    return 'Record';
  }
  if (flowCategoryId.startsWith('order_') ||
      flowCategoryId.startsWith('quotation_')) {
    return 'Save';
  }
  return 'Save';
}

String formatReminderSaveSuccess({
  required String fcid,
  required String name,
  required DateTime scheduledAt,
  String? savedTitle,
  String? note,
  String? priorityLabel,
}) {
  final loc = scheduledAt.toLocal();
  final whenLine =
      ReminderItem.formatPopupScheduleLine(loc.millisecondsSinceEpoch);
  final n = (note ?? '').trim();
  final rawTitle = (savedTitle ?? '').trim();
  final headline = rawTitle.isNotEmpty ? rawTitle : name.trim();

  if (fcid == 'reminder_task') {
    final pr = (priorityLabel ?? 'Medium').trim();
    final lowPr = pr.toLowerCase();
    final lines = <String>[
      if (headline.isNotEmpty) '✅ $headline' else '✅ Task saved',
      whenLine,
      if (lowPr != 'medium') '⚡ $pr',
      if (n.isNotEmpty) '',
      if (n.isNotEmpty) '🧾 $n',
      '',
      'Saved in: Reminders',
    ];
    return lines.join('\n');
  }

  return [
    if (headline.isNotEmpty) '✅ $headline' else '✅ Reminder saved',
    whenLine,
    if (n.isNotEmpty) '',
    if (n.isNotEmpty) '📝 $n',
    '',
    'Saved in: Reminders',
  ].join('\n');
}
