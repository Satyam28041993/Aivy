import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../data/chat_repository.dart';
import '../../payments/data/payment_repository.dart';
import '../../reminders/data/reminder_repository.dart';
import '../../reminders/data/reminder_save_validator.dart';
import '../../reminders/utils/reminder_doc_classification.dart';
import '../../reminders/utils/reminder_time_parser.dart';
import '../../projects/data/project_repository.dart';
import '../../projects/utils/project_confirm.dart';
import '../../structured_actions/data/structured_action_repository.dart';
import '../../structured_actions/models/structured_action.dart';
import '../../structured_actions/utils/name_normalize.dart';
import '../utils/aivy_response_formatter.dart';
import 'confirm_payload_mapper.dart';
import 'flow_formatters.dart';
import 'flow_step_engine.dart';

String _reminderPriorityToFirestore(Object? p) {
  final s = (p ?? 'Medium').toString().trim().toLowerCase();
  if (s == 'high') {
    return 'high';
  }
  if (s == 'low') {
    return 'low';
  }
  return 'medium';
}

String _flowNoteToWorkTitle(String note) {
  var s = note.trim();
  if (s.isEmpty) {
    return '';
  }
  final low = s.toLowerCase();
  if (low.endsWith('ke liye')) {
    s = s.substring(0, s.length - 7).trim();
  } else if (low.endsWith('k liye')) {
    s = s.substring(0, s.length - 6).trim();
  }
  return capitalizeWords(s);
}

String _buildControlledReminderTitle(
  String fcid, {
  required String nameCap,
  String? note,
}) {
  final work =
      (note != null && note.trim().isNotEmpty) ? _flowNoteToWorkTitle(note) : '';
  switch (fcid) {
    case 'reminder_call':
      if (work.isNotEmpty) {
        return 'Call $nameCap for $work';
      }
      return nameCap.isNotEmpty ? 'Call $nameCap' : 'Call reminder';
    case 'reminder_meeting':
      if (work.isNotEmpty) {
        return 'Meeting with $nameCap for $work';
      }
      return nameCap.isNotEmpty
          ? 'Meeting with $nameCap'
          : 'Meeting reminder';
    case 'reminder_followup':
      if (work.isNotEmpty) {
        return 'Follow-up with $nameCap for $work';
      }
      return nameCap.isNotEmpty
          ? 'Follow-up with $nameCap'
          : 'Follow-up';
    default:
      if (work.isNotEmpty) {
        return nameCap.isNotEmpty
            ? 'Reminder for $nameCap: $work'
            : 'Reminder: $work';
      }
      return nameCap.isNotEmpty ? 'Reminder for $nameCap' : 'Reminder';
  }
}

/// Outcome after a successful in-chat confirm (save + copy for user).
class FlowSaveOutcome {
  const FlowSaveOutcome({
    required this.message,
    this.lastActionId,
    this.lastActionType,
  });

  final String message;
  final String? lastActionId;
  final String? lastActionType;

  bool get didPersist => lastActionId != null && lastActionType != null;
}

/// Category-driven save: reminders → `reminders` subcollection, CRM → `structured_actions`.
class FlowSaveRouter {
  FlowSaveRouter({
    StructuredActionRepository? structured,
    ReminderRepository? reminders,
    PaymentRepository? payments,
    ChatRepository? ledger,
    ProjectRepository? projects,
  })  : _structured = structured ?? StructuredActionRepository(),
        _reminders = reminders ?? ReminderRepository(),
        _payments = payments ?? PaymentRepository(),
        _ledger = ledger,
        _orders = ledger ?? ChatRepository(),
        _projects = projects ?? ProjectRepository();

  final StructuredActionRepository _structured;
  final ReminderRepository _reminders;
  final PaymentRepository _payments;
  final ChatRepository? _ledger;
  final ChatRepository _orders;
  final ProjectRepository _projects;

  static String? _ledgerSourceCollection(String? lastActionType) {
    switch (lastActionType) {
      case 'payment_receipt':
      case 'payment_due_created':
        return 'payments';
      case 'reminder_created':
        return 'reminders';
      case 'created':
      case 'status_completed':
        return 'structured_actions';
      case 'order_created':
        return 'orders';
      case 'quotation_created':
      case 'quotation_followup_updated':
        return 'quotations';
      case 'project_items_created':
        return 'project_items';
      default:
        return null;
    }
  }

  Future<void> _persistLedger(
    String userId,
    Map<String, dynamic> confirmMap,
    FlowSaveOutcome outcome,
  ) async {
    final ledger = _ledger;
    if (ledger == null || !outcome.didPersist) {
      if (kDebugMode && !outcome.didPersist) {
        debugPrint(
          'AIVY_LEDGER_SKIP: didPersist=false msg=${outcome.message}',
        );
      }
      return;
    }
    final src = _ledgerSourceCollection(outcome.lastActionType);
    final payload = ConfirmPayloadMapper.buildLedgerPayload(
      confirmMap: confirmMap,
      lastActionType: outcome.lastActionType ?? 'unknown',
      savedDocId: outcome.lastActionId,
      sourceCollection: src,
    );
    ConfirmPayloadMapper.debugPayload('LEDGER', payload);
    try {
      await ledger.appendBusinessLedgerRecord(
        userId: userId,
        fields: payload,
      );
    } catch (e, st) {
      debugPrint('FlowSaveRouter: ledger append failed: $e\n$st');
    }
  }

  Future<FlowSaveOutcome> saveInChatConfirm({
    required String userId,
    required Map<String, dynamic> confirmMap,
  }) async {
    ConfirmPayloadMapper.debugDraftBeforeSave(confirmMap);
    final dbg = ConfirmPayloadMapper.buildLedgerPayload(
      confirmMap: confirmMap,
      lastActionType: 'routing',
      savedDocId: null,
      sourceCollection: null,
    );
    ConfirmPayloadMapper.debugPayload('ROUTER_ENTRY', dbg);

    if (ConfirmPayloadMapper.hasBlockingValidationErrors(confirmMap)) {
      ConfirmPayloadMapper.debugPayload('BLOCKED_VALIDATION', {});
      return const FlowSaveOutcome(
        message:
            'Save ke liye client / naam zaroori hain — flow dubara poore karein.',
      );
    }

    late final FlowSaveOutcome outcome;
    final fcid = (confirmMap['flowCategoryId'] as String? ?? '').trim();
    if (fcid.isEmpty) {
      outcome = await _saveStructuredCrm(
        userId: userId,
        map: confirmMap,
        successMessage: 'Done — record save ho gaya. ✓',
      );
    } else if (fcid == 'payment_followup' || fcid == 'followup_payment') {
      outcome = await _saveFollowupPaymentOnly(userId, confirmMap);
    } else if (fcid == 'payment_due' || fcid == 'payment_received') {
      final legacyId = (confirmMap['id'] as String? ?? '').trim();
      final clientId = (confirmMap['clientId'] as String? ?? '').trim();
      if (legacyId.isNotEmpty && clientId.isEmpty) {
        outcome = await _saveStructuredCrm(
          userId: userId,
          map: confirmMap,
          successMessage: 'Done — record update ho gaya. ✓',
        );
      } else {
        outcome = await _savePaymentFirestore(userId, confirmMap, fcid);
      }
    } else if (fcid.startsWith('quotation_')) {
      if (fcid == 'quotation_new') {
        outcome = await _saveQuotationNew(userId, confirmMap);
      } else if (fcid == 'quotation_followup') {
        outcome = await _saveQuotationFollowup(userId, confirmMap);
      } else {
        outcome = await _saveStructuredCrm(
          userId: userId,
          map: confirmMap,
          successMessage: 'Done — record save ho gaya. ✓',
        );
      }
    } else if (fcid.startsWith('order_')) {
      if (fcid == 'order_new') {
        outcome = await _saveOrderNew(userId, confirmMap);
      } else {
        outcome = await _saveStructuredCrm(
          userId: userId,
          map: confirmMap,
          successMessage: 'Done — record update ho gaya. ✓',
        );
      }
    } else if (fcid.startsWith('reminder_')) {
      outcome = await _saveReminder(userId, confirmMap, fcid);
    } else if (fcid == 'followup_client') {
      outcome = await _saveClientFollowupReminder(userId, confirmMap);
    } else if (fcid == 'personal_task' || fcid == 'personal_note') {
      outcome = await _savePersonalTaskReminder(userId, confirmMap);
    } else if (fcid == 'personal_birthday') {
      outcome = await _savePersonalBirthdayReminders(userId, confirmMap);
    } else if (fcid == kProjectFlowCategoryId) {
      outcome = await _saveProjectItems(userId, confirmMap);
    } else {
      outcome = await _saveStructuredCrm(
        userId: userId,
        map: confirmMap,
        successMessage: 'Done — record save ho gaya. ✓',
      );
    }

    await _persistLedger(userId, confirmMap, outcome);
    return outcome;
  }

  Future<FlowSaveOutcome> _saveProjectItems(
    String userId,
    Map<String, dynamic> m,
  ) async {
    final items = projectItemsFromMap(m);
    if (items.isEmpty) {
      return const FlowSaveOutcome(
        message: 'Koi project item nahi mila — dump dubara bhejo.',
      );
    }
    final name =
        (m['projectName'] as String? ?? m['name'] as String? ?? '').trim();
    if (name.isEmpty) {
      return const FlowSaveOutcome(
        message: 'Project naam missing — Edit karke naam likho.',
      );
    }
    final client = (m['client'] as String? ?? '').trim();
    final existingId = (m['projectId'] as String? ?? '').trim();
    var project = existingId.isNotEmpty
        ? await _projects.getProject(userId, existingId)
        : await _projects.findByNameOrClient(userId, name);
    project ??= await _projects.createProject(
      uid: userId,
      name: name,
      client: client,
      notes: (m['sourceText'] as String? ?? '').trim(),
    );

    final saved = await _projects.addItems(
      uid: userId,
      project: project,
      items: items,
    );
    var reminderCount = 0;
    for (var i = 0; i < saved.length; i++) {
      final item = saved[i];
      final dueMs = item.dueAtMs ??
          (items.length > i ? (items[i]['dueAtMs'] as num?)?.toInt() : null);
      if (dueMs == null || dueMs <= 0) {
        continue;
      }
      final waiting = item.waitingOn;
      final isWait = item.status == 'waiting_on_them' || item.kind == 'followup';
      final title = isWait
          ? (waiting.isNotEmpty
              ? '${project.name}: $waiting se ${item.title}'
              : '${project.name}: ${item.title} (waiting on them)')
          : '${project.name}: ${item.title}';
      try {
        final rid = await _reminders.createReminder(
          userId: userId,
          title: title,
          scheduledAt: DateTime.fromMillisecondsSinceEpoch(dueMs),
          type: isWait ? 'followup' : 'task',
          subType: 'project_item',
          note: item.notes.isNotEmpty ? item.notes : item.kind,
          clientName: client.isNotEmpty ? client : project.name,
          extraFields: {
            'projectId': project.id,
            'projectItemId': item.id,
            'isFollowUp': isWait,
          },
        );
        reminderCount++;
        await _projects.setItemReminderId(
          uid: userId,
          itemId: item.id,
          reminderId: rid,
        );
      } catch (e, st) {
        debugPrint('FlowSaveRouter: project item reminder failed: $e\n$st');
      }
    }
    final waitN =
        saved.where((s) => s.status == 'waiting_on_them').length;
    final bits = <String>[
      '${project.name}: ${saved.length} items save ho gaye.',
      if (waitN > 0) '$waitN waiting on them.',
      if (reminderCount > 0) '$reminderCount reminder lagaye (same notifications).',
    ];
    return FlowSaveOutcome(
      message: bits.join(' '),
      lastActionId: project.id,
      lastActionType: 'project_items_created',
    );
  }

  Future<FlowSaveOutcome> _saveOrderNew(
    String userId,
    Map<String, dynamic> m,
  ) async {
    final name =
        (m[FlowStepEngine.kName] as String? ??
                m['name'] as String? ??
                m['clientName'] as String? ??
                '')
            .trim();
    if (name.length < 2) {
      return const FlowSaveOutcome(
        message: 'Client naam missing — dubara try karein.',
      );
    }
    final amount = ConfirmPayloadMapper.coerceDoubleAmount(
      m[FlowStepEngine.kAmount] ?? m['amount'],
    );
    if (amount == null || amount <= 0) {
      return const FlowSaveOutcome(
        message: 'Amount missing — new order ke liye amount zaroori hai.',
      );
    }
    final note =
        (m[FlowStepEngine.kNote] as String? ?? m['note'] as String? ?? '').trim();
    final orderId = await _orders.createOrder(
      userId: userId,
      clientName: capitalizeWords(name),
      amount: amount,
      note: note.isEmpty ? null : note,
    );
    return FlowSaveOutcome(
      message:
          'Order saved — ${capitalizeWords(name)} ₹${_fmtAmt(amount)} ✓',
      lastActionId: orderId,
      lastActionType: 'order_created',
    );
  }

  DateTime? _resolveScheduleFromMap(Map<String, dynamic> m) {
    final dr = m[FlowStepEngine.kDate] ?? m['date'];
    if (dr is num) {
      final dt = DateTime.fromMillisecondsSinceEpoch(dr.toInt());
      return dt;
    }
    if (dr is String) {
      return ReminderTimeParser.resolveScheduledTimeFromPlainText(dr);
    }
    return null;
  }

  Future<FlowSaveOutcome> _saveQuotationNew(
    String userId,
    Map<String, dynamic> m,
  ) async {
    final name =
        (m[FlowStepEngine.kName] as String? ??
                m['name'] as String? ??
                m['clientName'] as String? ??
                '')
            .trim();
    if (name.length < 2) {
      return const FlowSaveOutcome(
        message: 'Client naam missing — quotation ke liye zaroori hai.',
      );
    }
    final amount = ConfirmPayloadMapper.coerceDoubleAmount(
      m[FlowStepEngine.kAmount] ?? m['amount'],
    );
    if (amount == null || amount <= 0) {
      return const FlowSaveOutcome(
        message: 'Amount missing — quotation ke liye amount zaroori hai.',
      );
    }
    final scheduled = _resolveScheduleFromMap(m);
    if (scheduled == null) {
      return const FlowSaveOutcome(
        message: 'Follow-up date/time clear nahi — dubara try karein.',
      );
    }
    final note =
        (m[FlowStepEngine.kNote] as String? ?? m['note'] as String? ?? '').trim();
    final nameCap = capitalizeWords(name);
    final quoteId = await _orders.createQuotation(
      userId: userId,
      clientName: nameCap,
      amount: amount,
      followUpDateMs: scheduled.millisecondsSinceEpoch,
      note: note.isEmpty ? null : note,
    );
    await _reminders.createReminder(
      userId: userId,
      title: 'Quotation follow-up: $nameCap',
      scheduledAt: scheduled,
      type: 'followup',
      subType: 'quotation_followup',
      note: note.isEmpty ? 'Quotation ₹${_fmtAmt(amount)}' : note,
      clientName: nameCap,
      extraFields: {
        'quotationId': quoteId,
        'isFollowUp': true,
      },
    );
    return FlowSaveOutcome(
      message:
          'Quotation saved — $nameCap ₹${_fmtAmt(amount)} ✓\nFollow-up reminder set: ${DateFormat('d MMM, hh:mm a').format(scheduled.toLocal())}',
      lastActionId: quoteId,
      lastActionType: 'quotation_created',
    );
  }

  Future<FlowSaveOutcome> _saveQuotationFollowup(
    String userId,
    Map<String, dynamic> m,
  ) async {
    final quoteId = (m['quotationId'] as String? ?? '').trim();
    if (quoteId.isEmpty) {
      return const FlowSaveOutcome(
        message: 'Quotation pick missing — follow-up set karne ke liye list se choose karein.',
      );
    }
    final name =
        (m[FlowStepEngine.kName] as String? ??
                m['name'] as String? ??
                m['clientName'] as String? ??
                '')
            .trim();
    if (name.length < 2) {
      return const FlowSaveOutcome(
        message: 'Client naam missing — follow-up set nahi ho paya.',
      );
    }
    final scheduled = _resolveScheduleFromMap(m);
    if (scheduled == null) {
      return const FlowSaveOutcome(
        message: 'Follow-up date/time clear nahi — dubara try karein.',
      );
    }
    final note =
        (m[FlowStepEngine.kNote] as String? ?? m['note'] as String? ?? '').trim();
    final nameCap = capitalizeWords(name);
    await _orders.updateQuotationFollowUp(
      userId: userId,
      quotationId: quoteId,
      followUpDateMs: scheduled.millisecondsSinceEpoch,
      note: note.isEmpty ? null : note,
    );
    await _reminders.rescheduleQuotationFollowUpReminder(
      userId: userId,
      quotationId: quoteId,
      scheduledAt: scheduled,
      clientName: nameCap,
      note: note.isEmpty ? null : note,
    );
    return FlowSaveOutcome(
      message:
          'Quotation follow-up reset ho gaya ✓\nNext follow-up: ${DateFormat('d MMM, hh:mm a').format(scheduled.toLocal())}',
      lastActionId: quoteId,
      lastActionType: 'quotation_followup_updated',
    );
  }

  Future<FlowSaveOutcome> _saveClientFollowupReminder(
    String userId,
    Map<String, dynamic> m,
  ) async {
    final name =
        (m[FlowStepEngine.kName] as String? ??
                m['name'] as String? ??
                m['clientName'] as String? ??
                '')
            .trim();
    if (name.length < 2) {
      return const FlowSaveOutcome(
        message: 'Client naam missing — follow-up set karne ke liye zaroori hai.',
      );
    }
    final dr = m[FlowStepEngine.kDate] ?? m['date'];
    DateTime? scheduled;
    if (dr is num) {
      scheduled = DateTime.fromMillisecondsSinceEpoch(dr.toInt());
    } else if (dr is String) {
      scheduled = ReminderTimeParser.resolveScheduledTimeFromPlainText(dr);
    }
    if (scheduled == null) {
      return const FlowSaveOutcome(
        message: 'Follow-up date/time clear nahi — dubara try karein.',
      );
    }
    final note =
        (m[FlowStepEngine.kNote] as String? ?? m['note'] as String? ?? '').trim();
    final nameCap = capitalizeWords(name);
    final reminderId = await _reminders.createReminder(
      userId: userId,
      title: 'Follow-up with $nameCap',
      scheduledAt: scheduled,
      type: 'followup',
      subType: 'followup_client',
      note: note.isEmpty ? null : note,
      clientName: nameCap,
      extraFields: const {
        'isFollowUp': true,
      },
    );
    return FlowSaveOutcome(
      message:
          'Follow-up set ho gaya ✓\nClient: $nameCap\nNext follow-up: ${DateFormat('d MMM, hh:mm a').format(scheduled.toLocal())}',
      lastActionId: reminderId,
      lastActionType: 'reminder_created',
    );
  }

  Future<FlowSaveOutcome> _savePersonalTaskReminder(
    String userId,
    Map<String, dynamic> m,
  ) async {
    final task =
        (m[FlowStepEngine.kName] as String? ??
                m['name'] as String? ??
                m[FlowStepEngine.kTaskTitle] as String? ??
                '')
            .trim();
    if (task.length < 2) {
      return const FlowSaveOutcome(
        message: 'Task missing — personal reminder ke liye task zaroori hai.',
      );
    }
    final scheduled = _resolveScheduleFromMap(m);
    if (scheduled == null) {
      return const FlowSaveOutcome(
        message: 'Date/time clear nahi — personal reminder set nahi ho paya.',
      );
    }
    final note =
        (m[FlowStepEngine.kNote] as String? ?? m['note'] as String? ?? '').trim();
    final reminderId = await _reminders.createReminder(
      userId: userId,
      title: task,
      scheduledAt: scheduled,
      type: 'task',
      subType: 'personal_task',
      note: note.isEmpty ? null : note,
      extraFields: const {
        'isFollowUp': false,
      },
    );
    return FlowSaveOutcome(
      message:
          'Personal reminder set ho gaya ✓\nTask: $task\nRemind on: ${DateFormat('d MMM, hh:mm a').format(scheduled.toLocal())}',
      lastActionId: reminderId,
      lastActionType: 'reminder_created',
    );
  }

  ({int day, int month, int? year})? _parseBirthdayParts(String raw) {
    final s = raw.trim();
    if (s.isEmpty) {
      return null;
    }
    final m1 = RegExp(
      r'^(\d{1,2})[/-](\d{1,2})(?:[/-](\d{4}))?$',
    ).firstMatch(s);
    if (m1 != null) {
      final d = int.tryParse(m1.group(1) ?? '');
      final mo = int.tryParse(m1.group(2) ?? '');
      final y = int.tryParse(m1.group(3) ?? '');
      if (d != null && mo != null && d >= 1 && d <= 31 && mo >= 1 && mo <= 12) {
        return (day: d, month: mo, year: y);
      }
    }
    return null;
  }

  DateTime _nextBirthdayAt({
    required int day,
    required int month,
    required DateTime now,
  }) {
    var target = DateTime(now.year, month, day, 9, 0);
    if (target.isBefore(DateTime(now.year, now.month, now.day))) {
      target = DateTime(now.year + 1, month, day, 9, 0);
    }
    return target;
  }

  Future<FlowSaveOutcome> _savePersonalBirthdayReminders(
    String userId,
    Map<String, dynamic> m,
  ) async {
    final name =
        (m[FlowStepEngine.kName] as String? ?? m['name'] as String? ?? '')
            .trim();
    if (name.length < 2) {
      return const FlowSaveOutcome(
        message: 'Name missing — birthday tracker ke liye zaroori hai.',
      );
    }
    final birthRaw =
        (m[FlowStepEngine.kBirthDate] as String? ?? m['birthDate'] as String? ?? '')
            .trim();
    final parts = _parseBirthdayParts(birthRaw);
    if (parts == null) {
      return const FlowSaveOutcome(
        message: 'Birthday date clear nahi — 20-05 format me likhiye.',
      );
    }
    final note =
        (m[FlowStepEngine.kNote] as String? ?? m['note'] as String? ?? '').trim();
    final now = DateTime.now();
    final target = _nextBirthdayAt(
      day: parts.day,
      month: parts.month,
      now: now,
    );
    const offsets = <int>[7, 2, 1, 0];
    String? firstReminderId;
    var created = 0;
    for (final offset in offsets) {
      var scheduled = target.subtract(Duration(days: offset));
      if (scheduled.isBefore(now)) {
        if (offset == 0) {
          scheduled = now.add(const Duration(minutes: 2));
        } else {
          continue;
        }
      }
      final title = offset == 0
          ? '$name ka birthday aaj hai'
          : '$name ka birthday ${offset == 1 ? 'kal' : '$offset din baad'} hai';
      final rid = await _reminders.createReminder(
        userId: userId,
        title: title,
        scheduledAt: scheduled,
        type: 'task',
        subType: 'personal_birthday',
        note: note.isEmpty ? 'Birthday reminder' : note,
        extraFields: {
          'birthdayName': name,
          'birthdayDate': birthRaw,
          'birthdayOffsetDays': offset,
          'isFollowUp': false,
        },
      );
      firstReminderId ??= rid;
      created++;
    }
    if (created == 0) {
      return const FlowSaveOutcome(
        message: 'Birthday reminders create nahi ho paye — dubara try karein.',
      );
    }
    return FlowSaveOutcome(
      message:
          'Birthday tracker set ho gaya ✓\n$name ke liye 7 din, 2 din, 1 din aur same-day reminders schedule kiye.',
      lastActionId: firstReminderId,
      lastActionType: 'reminder_created',
    );
  }

  Future<FlowSaveOutcome> _saveFollowupPaymentOnly(
    String userId,
    Map<String, dynamic> m,
  ) async {
    final clientId = (m['clientId'] as String? ?? '').trim();
    final name =
        (m[FlowStepEngine.kName] as String? ?? m['name'] as String? ?? '')
            .trim();
    if (clientId.isEmpty || name.isEmpty) {
      return const FlowSaveOutcome(
        message: 'Follow-up save ke liye client zaroori hai — dubara chunein.',
      );
    }
    final nameCap = capitalizeWords(name);

    final amtRaw = m[FlowStepEngine.kAmount] ?? m['amount'];
    final amount = (amtRaw is num) ? amtRaw.toDouble() : 0.0;

    final dr = m[FlowStepEngine.kDate] ?? m['date'];
    int? dueMs;
    if (dr is num) {
      dueMs = dr.toInt();
    } else if (dr is String) {
      final day = ReminderTimeParser.resolveDateDayForReminderFlow(dr);
      dueMs = day?.millisecondsSinceEpoch;
    }

    if (amount > 0 && dueMs != null) {
      final noteRaw =
          (m[FlowStepEngine.kNote] as String? ?? m['note'] as String? ?? '')
              .trim();
      final dueId = await _payments.createPaymentDue(
        userId: userId,
        clientId: clientId,
        clientName: nameCap,
        amount: amount,
        dueDateMs: dueMs,
        note: noteRaw.isNotEmpty ? noteRaw : null,
      );
      await _payments.syncClientOutstandingForClient(userId, clientId);

      final dueDate = DateTime.fromMillisecondsSinceEpoch(dueMs);
      final reminderAt = DateTime(
        dueDate.year, dueDate.month, dueDate.day, 11, 0,
      );
      final reminderTitle = 'Payment follow-up: $nameCap';
      final reminderNote =
          '₹${_fmtAmt(amount)} due on ${DateFormat('d MMM').format(dueDate)}';
      await _reminders.createReminder(
        userId: userId,
        title: reminderTitle,
        scheduledAt: reminderAt,
        type: 'payment',
        subType: 'followup',
        note: reminderNote,
        clientName: nameCap,
      );

      final cur = NumberFormat.currency(
        locale: 'en_IN', symbol: '₹', decimalDigits: 0,
      );
      final dueLabel = DateFormat('d MMM').format(dueDate);
      return FlowSaveOutcome(
        message:
            '${cur.format(amount)} due added for $nameCap ($dueLabel) ✓\n'
            'Reminder set: $dueLabel 11:00 AM',
        lastActionId: dueId,
        lastActionType: 'payment_due_created',
      );
    }

    final noteTrimmed =
        (m[FlowStepEngine.kNote] as String? ?? m['note'] as String?)?.trim();
    final title = 'Follow-up with $nameCap for payment';
    final noteOut =
        (noteTrimmed != null && noteTrimmed.isNotEmpty) ? noteTrimmed : null;
    final d = StructuredAction(
      type: 'followup',
      subType: 'payment',
      name: nameCap,
      nameLower: normalizeName(name),
      note: noteOut,
      status: 'pending',
      createdAt: DateTime.now(),
      title: title,
      clientId: clientId,
    );
    final id = await _structured.save(d, userId: userId);
    return FlowSaveOutcome(
      message: 'Reminder set — $title ✓',
      lastActionId: id,
      lastActionType: 'created',
    );
  }

  Future<FlowSaveOutcome> _savePaymentFirestore(
    String userId,
    Map<String, dynamic> m,
    String fcid,
  ) async {
    final clientId = (m['clientId'] as String? ?? '').trim();
    final name = (m['name'] as String? ?? '').trim();
    if (clientId.isEmpty) {
      return const FlowSaveOutcome(
        message: 'Bina client ke payment save nahi hota — pehle client chunein.',
      );
    }
    if (name.isEmpty) {
      return const FlowSaveOutcome(
        message: 'Client naam missing — dubara try karein.',
      );
    }
    final amtRaw = m['amount'];
    final amount = ConfirmPayloadMapper.coerceDoubleAmount(amtRaw);
    if (fcid == 'payment_received') {
      if (amount == null || amount <= 0) {
        return const FlowSaveOutcome(
          message: 'Amount clear nahi — payment receive ke liye amount zaroori hai.',
        );
      }
      int? receivedAtMs;
      final dr = m[FlowStepEngine.kDate] ?? m['date'];
      if (dr is num) {
        receivedAtMs = dr.toInt();
      } else if (dr is String) {
        final day = ReminderTimeParser.resolveDateDayForReminderFlow(dr);
        receivedAtMs = day?.millisecondsSinceEpoch;
      }
      final paymentNote = (m['paymentNote'] as String? ?? m['note'] as String? ?? '')
          .trim();
      final paymentMode = (m['paymentMode'] as String? ?? '').trim();
      final receiptRaw = m['receiptNumber'];
      Object? receiptNumber;
      if (receiptRaw != null && receiptRaw.toString().trim().isNotEmpty) {
        receiptNumber = receiptRaw;
      }
      var linked = (m['linkedPaymentId'] as String? ?? '').trim();
      final structLegacy = (m['structuredLegacyId'] as String? ?? '').trim();
      if (structLegacy.isNotEmpty) {
        final leg = await _structured.tryGetById(userId, structLegacy);
        if (leg == null || leg.type != 'payment') {
          return const FlowSaveOutcome(
            message: 'Legacy payment row nahi mila — dubara chunein.',
          );
        }
        try {
          linked = await _payments.migrateStructuredPaymentDueToPayments(
            userId: userId,
            structuredActionId: structLegacy,
            clientId: clientId,
            clientDisplayName: name,
          );
        } catch (e, st) {
          debugPrint('FlowSaveRouter: legacy migrate failed: $e\n$st');
          return const FlowSaveOutcome(
            message: 'Migrate nahi ho paya — dubara try karein.',
          );
        }
      }
      try {
        final id = await _payments.settlePaymentReceived(
          userId: userId,
          clientId: clientId,
          clientName: name,
          receivedAmount: amount,
          linkedPaymentId: linked.isEmpty ? null : linked,
          paymentNote: paymentNote.isEmpty ? null : paymentNote,
          paymentMode: paymentMode.isEmpty ? null : paymentMode,
          receiptNumber: receiptNumber,
          receivedAtMs: receivedAtMs,
        );
        return FlowSaveOutcome(
          message:
              'Payment received — ${capitalizeWords(name)} ₹${_fmtAmt(amount)} ✓'
              '${linked.isNotEmpty ? ' (linked)' : ''}',
          lastActionId: id,
          lastActionType: 'payment_receipt',
        );
      } catch (e, st) {
        debugPrint('FlowSaveRouter: settlePaymentReceived failed: $e\n$st');
        return FlowSaveOutcome(
          message:
              'Save nahi ho paya: ${e.toString().contains('exceeds') ? 'amount remaining se zyada hai' : 'dubara try karein'}',
        );
      }
    }
    if (amount == null || amount <= 0) {
      return const FlowSaveOutcome(
        message: 'Amount missing — payment due ke liye amount zaroori hai.',
      );
    }
    final dr = m[FlowStepEngine.kDate] ?? m['date'];
    int? dueMs;
    if (dr is num) {
      dueMs = dr.toInt();
    } else if (dr is String) {
      final day = ReminderTimeParser.resolveDateDayForReminderFlow(dr);
      dueMs = day?.millisecondsSinceEpoch;
    }
    if (dueMs == null) {
      return const FlowSaveOutcome(
        message: 'Due date clear nahi — dubara try karein.',
      );
    }
    final id = await _payments.createPaymentDue(
      userId: userId,
      clientId: clientId,
      clientName: name,
      amount: amount,
      dueDateMs: dueMs,
      note: (m['note'] as String? ?? '').trim().isEmpty
          ? null
          : m['note'] as String?,
    );
    await _payments.syncClientOutstandingForClient(userId, clientId);
    final nameCap = capitalizeWords(name);
    final cur = NumberFormat.currency(
      locale: 'en_IN',
      symbol: '₹',
      decimalDigits: 0,
    );
    final dueLabel = DateFormat('d MMM')
        .format(DateTime.fromMillisecondsSinceEpoch(dueMs));
    return FlowSaveOutcome(
      message:
          '${cur.format(amount)} due added for $nameCap ($dueLabel) ✓',
      lastActionId: id,
      lastActionType: 'payment_due_created',
    );
  }

  String _fmtAmt(double a) {
    final s = a.toStringAsFixed(0);
    final buf = StringBuffer();
    var c = 0;
    for (var i = s.length - 1; i >= 0; i--) {
      buf.write(s[i]);
      c++;
      if (c == 3 && i > 0 && s[i - 1] != '-') {
        buf.write(',');
        c = 0;
      }
    }
    return buf.toString().split('').reversed.join();
  }

  Future<FlowSaveOutcome> _saveStructuredCrm({
    required String userId,
    required Map<String, dynamic> map,
    required String successMessage,
  }) async {
    final d = _draftFromMap(map);
    if (d.id != null) {
      await _structured.setStatus(userId, d.id!, 'completed');
      return FlowSaveOutcome(
        message: 'Done — record update ho gaya. ✓',
        lastActionId: d.id,
        lastActionType: 'status_completed',
      );
    }
    final id = await _structured.save(d, userId: userId);
    return FlowSaveOutcome(
      message: successMessage,
      lastActionId: id,
      lastActionType: 'created',
    );
  }

  Future<FlowSaveOutcome> _saveReminder(
    String userId,
    Map<String, dynamic> m,
    String fcid,
  ) async {
    final note = m[FlowStepEngine.kNote] as String? ?? m['note'] as String?;
    final dr = m[FlowStepEngine.kDate] ?? m['date'];
    DateTime? day;
    if (dr is num) {
      final raw = DateTime.fromMillisecondsSinceEpoch(dr.toInt());
      day = DateTime(raw.year, raw.month, raw.day);
    } else if (dr is String) {
      day = ReminderTimeParser.resolveScheduledTimeFromPlainText(dr);
      if (day != null) {
        day = DateTime(day.year, day.month, day.day);
      }
    }
    if (day == null) {
      return const FlowSaveOutcome(
        message: 'Date error — phir se try karein.',
      );
    }
    var embeddedDaytimeMin = 0;
    if (dr is num) {
      final raw = DateTime.fromMillisecondsSinceEpoch(dr.toInt());
      embeddedDaytimeMin = raw.hour * 60 + raw.minute;
    }
    var min = 11 * 60;
    final tRaw = m[FlowStepEngine.kTime] ?? m['time'];
    final timeSkipped = m['timeSkipped'] == true;
    if (tRaw is int) {
      min = tRaw;
    }
    if (timeSkipped && embeddedDaytimeMin != 0) {
      min = embeddedDaytimeMin;
    }
    final h = min ~/ 60;
    final mi = min % 60;
    var scheduled = DateTime(day.year, day.month, day.day, h, mi);
    final now = DateTime.now();
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    if (fcid == 'reminder_task') {
      final taskRaw =
          (m[FlowStepEngine.kTaskTitle] as String? ??
                  m['taskTitle'] as String? ??
                  '')
              .trim();
      if (taskRaw.isEmpty) {
        return const FlowSaveOutcome(
          message: 'Task missing — phir se try karein.',
        );
      }
      final taskTitleCap = capitalizeWords(taskRaw);
      final clientRaw = (m['clientName'] as String? ?? '').trim();
      final clientCap =
          clientRaw.isNotEmpty ? capitalizeWords(clientRaw) : '';
      final title = clientCap.isNotEmpty
          ? '$taskTitleCap for $clientCap'
          : taskTitleCap;
      final noteTrimmed = note?.trim();
      final noteOut = (noteTrimmed != null && noteTrimmed.isNotEmpty)
          ? capitalizeWords(noteTrimmed)
          : null;
      final pri = _reminderPriorityToFirestore(m['priority']);
      final validation = ReminderSaveValidator.validateWrite(
        title: title,
        scheduledAt: scheduled,
        clientName: clientCap.isNotEmpty ? clientCap : null,
        requireClientName: false,
      );
      if (validation != null) {
        return FlowSaveOutcome(message: validation);
      }
      final id = await _reminders.createReminder(
        userId: userId,
        title: title,
        scheduledAt: scheduled,
        type: 'task',
        subType: fcid,
        note: noteOut,
        clientName: clientCap.isNotEmpty ? clientCap : null,
        priority: pri,
      );
      return FlowSaveOutcome(
        message: formatReminderSaveSuccess(
          fcid: fcid,
          name: taskTitleCap,
          savedTitle: title,
          scheduledAt: scheduled,
          note: noteOut,
          priorityLabel: (m['priority'] ?? 'Medium').toString(),
        ),
        lastActionId: id,
        lastActionType: 'reminder_created',
      );
    }

    final name =
        (m[FlowStepEngine.kName] as String? ?? m['name'] as String? ?? '')
            .trim();
    final nameCap = capitalizeWords(name);
    final noteTrimmed = note?.trim();
    final noteOut = (noteTrimmed != null && noteTrimmed.isNotEmpty)
        ? capitalizeWords(noteTrimmed)
        : null;
    final title = _buildControlledReminderTitle(
      fcid,
      nameCap: nameCap,
      note: noteTrimmed,
    );
    final validation = ReminderSaveValidator.validateWrite(
      title: title,
      scheduledAt: scheduled,
      clientName: nameCap.isNotEmpty ? nameCap : null,
      requireClientName: fcid == 'reminder_call',
    );
    if (validation != null) {
      return FlowSaveOutcome(message: validation);
    }
    final cls = reminderDocClassificationFromFlowCategoryId(fcid);
    final id = await _reminders.createReminder(
      userId: userId,
      title: title,
      scheduledAt: scheduled,
      type: cls.type,
      subType: cls.subType,
      note: noteOut,
      clientName: nameCap.isNotEmpty ? nameCap : null,
    );
    return FlowSaveOutcome(
      message: formatReminderSaveSuccess(
        fcid: fcid,
        name: nameCap,
        savedTitle: title,
        scheduledAt: scheduled,
        note: noteOut,
      ),
      lastActionId: id,
      lastActionType: 'reminder_created',
    );
  }

  StructuredAction _draftFromMap(Map<String, dynamic> m) {
    return draftFromMapForSave(m);
  }
}

/// Shared between [FlowSaveRouter] and [ControlledChatFlow] (same semantics).
StructuredAction draftFromMapForSave(Map<String, dynamic> m) {
  DateTime? date;
  final dr = m['date'];
  if (dr is num) {
    date = DateTime.fromMillisecondsSinceEpoch(dr.toInt());
  } else if (dr is String) {
    date = ReminderTimeParser.resolveScheduledTimeFromPlainText(dr);
  }
  final fcid = (m['flowCategoryId'] as String? ?? '').trim();
  var type = (m['type'] as String? ?? '').trim();
  var subType = (m['subType'] as String? ?? '').trim();
    if (fcid.isNotEmpty) {
    if (fcid == 'payment_followup' || fcid == 'followup_payment') {
      type = 'followup';
      subType = 'payment';
    } else if (fcid.startsWith('payment_')) {
      type = 'payment';
      subType = fcid;
    } else if (fcid.startsWith('reminder_') ||
        fcid.startsWith('followup_') ||
        fcid.startsWith('task_')) {
      final c = reminderDocClassificationFromFlowCategoryId(fcid);
      type = c.type;
      subType = c.subType;
    } else {
      final u = fcid.indexOf('_');
      if (u > 0) {
        type = fcid.substring(0, u);
        if (u + 1 < fcid.length) {
          subType = fcid.substring(u + 1);
        }
      }
    }
  }
  if (type.isEmpty) {
    type = 'payment';
  }
  if (subType.isEmpty) {
    subType = 'payment_due';
  }
  final nameStr = (() {
    if (fcid == 'reminder_task') {
      return (m['clientName'] as String? ?? '').trim();
    }
    return (m['name'] as String? ?? '').trim();
  })();
  final cid = (m['clientId'] as String? ?? '').trim();
  final lid = (m['linkedPaymentId'] as String? ?? '').trim();
  final tit = (m['title'] as String? ?? '').trim();
  return StructuredAction(
    id: m['id'] as String?,
    type: type,
    subType: subType,
    name: nameStr,
    nameLower: (m['nameLower'] as String?)?.trim().isNotEmpty == true
        ? m['nameLower'] as String
        : (nameStr.isNotEmpty ? normalizeName(nameStr) : ''),
    amount: m['amount'] is num
        ? (m['amount'] as num).toDouble()
        : null,
    date: date,
    note: m['note'] as String?,
    status: ((m['status'] as String?) ?? 'pending').trim().isEmpty
        ? 'pending'
        : (m['status'] as String?) ?? 'pending',
    createdAt: DateTime.now(),
    title: tit.isEmpty ? null : tit,
    clientId: cid.isEmpty ? null : cid,
    linkedPaymentId: lid.isEmpty ? null : lid,
  );
}
