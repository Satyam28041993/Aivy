class AivyAiResponse {
  const AivyAiResponse({
    required this.contextType,
    required this.category,
    required this.memoryCategory,
    required this.clientName,
    required this.summary,
    required this.keyPoints,
    required this.actionItems,
    required this.followUpSuggestions,
    required this.reminderSuggestions,
    required this.assistantReply,
    this.intent = 'general',
    this.jobRecord = const PgplJobRecord.empty(),
    this.paymentRecord = const PgplPaymentRecord.empty(),
    this.transcript,
    this.goalRecord,
    this.createdTaskIds = const [],
    this.data,
    this.showBadge = false,
    this.projectDraft,
  });

  /// Backend PGPL / rule classifier: `job_new`, `job_dispatch`, `order_create`,
  /// `payment_due`, `report_request`, `general`, and analytics ids.
  final String intent;
  final PgplJobRecord jobRecord;
  final PgplPaymentRecord paymentRecord;

  final String contextType;

  /// High-level tag inferred by the backend: `client`, `work`, `personal`,
  /// or `general`. Drives dashboard filtering.
  final String category;

  /// What kind of memory was saved: `quotation`, `meeting`, `task`, `note`,
  /// or `general`. Used for memory queries.
  final String memoryCategory;

  /// Optional client or person name when detected in the input.
  final String clientName;
  final String summary;
  final List<String> keyPoints;
  final List<String> actionItems;
  final List<FollowUpSuggestion> followUpSuggestions;
  final List<ReminderSuggestion> reminderSuggestions;
  final String assistantReply;

  /// Raw Whisper transcription returned for voice inputs. Null for text
  /// messages or if the backend did not include it.
  final String? transcript;

  /// Optional monthly goal from the model (persisted under `users/.../goals`).
  final GoalRecord? goalRecord;
  final List<String> createdTaskIds;

  /// Server-computed fields for data-driven intents (e.g. quotation counts).
  final Map<String, dynamic>? data;

  /// When true, UI may show a dispatch confirmation chip (e.g. after order dispatch).
  final bool showBadge;

  /// Confirmable project extract from `aivyProcess` (`project_extract`).
  final Map<String, dynamic>? projectDraft;

  factory AivyAiResponse.fromJson(Map<String, dynamic> json) {
    final summary = (json['summary'] as String? ?? '').trim();
    final keyPoints = _readStringList(json['keyPoints']);
    final actionItems = _readStringList(json['actionItems']);
    final followUps = _readFollowUps(json['followUpSuggestions']);
    final reminders = _readReminders(json['reminderSuggestions']);
    final assistantReply = (json['message'] as String? ??
            json['userReply'] as String? ??
            json['assistantReply'] as String? ??
            '')
        .trim();
    final transcriptRaw = (json['transcript'] as String?)?.trim();
    final createdTaskIds = _readStringList(json['createdTaskIds']);
    GoalRecord? goalRecord;
    final goalRaw = json['goalRecord'];
    if (goalRaw is Map) {
      goalRecord = GoalRecord.tryFromJson(Map<String, dynamic>.from(goalRaw));
    }

    final intent = _normalizeAivyIntent(json['intent'] as String?);
    final jobRecord = PgplJobRecord.fromJson(json['jobRecord']);
    final paymentRecord = PgplPaymentRecord.fromJson(json['paymentRecord']);
    final dataRaw = json['data'];
    final Map<String, dynamic>? dataMap = dataRaw is Map
        ? Map<String, dynamic>.from(dataRaw)
        : null;
    final showBadge = json['showBadge'] == true;
    Map<String, dynamic>? projectDraft;
    final pdRaw = json['projectDraft'];
    if (pdRaw is Map) {
      projectDraft = Map<String, dynamic>.from(pdRaw);
    } else if (dataMap != null && dataMap['items'] is List) {
      final kind = dataMap['analyticsKind']?.toString();
      if (kind == 'project_extract' || dataMap['projectDraft'] == true) {
        projectDraft = Map<String, dynamic>.from(dataMap);
      }
    }

    return AivyAiResponse(
      contextType: (json['contextType'] as String? ?? 'note').trim(),
      category: _normalizeCategory(json['category'] as String?),
      memoryCategory: _normalizeMemoryCategory(json['memoryCategory'] as String?),
      clientName: (json['clientName'] as String? ?? '').trim(),
      summary: summary,
      keyPoints: keyPoints,
      actionItems: actionItems,
      followUpSuggestions: followUps,
      reminderSuggestions: reminders,
      assistantReply: assistantReply,
      intent: intent,
      jobRecord: jobRecord,
      paymentRecord: paymentRecord,
      transcript: (transcriptRaw == null || transcriptRaw.isEmpty)
          ? null
          : transcriptRaw,
      goalRecord: goalRecord,
      createdTaskIds: createdTaskIds,
      data: dataMap,
      showBadge: showBadge,
      projectDraft: projectDraft,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'intent': intent,
      'jobRecord': jobRecord.toJson(),
      'paymentRecord': paymentRecord.toJson(),
      'contextType': contextType,
      'category': category,
      'memoryCategory': memoryCategory,
      'clientName': clientName,
      'summary': summary,
      'keyPoints': keyPoints,
      'actionItems': actionItems,
      'followUpSuggestions': followUpSuggestions
          .map((e) => e.toJson())
          .toList(),
      'reminderSuggestions': reminderSuggestions
          .map((e) => e.toJson())
          .toList(),
      'assistantReply': assistantReply,
      'userReply': assistantReply,
      if (transcript != null) 'transcript': transcript,
      if (goalRecord != null) 'goalRecord': goalRecord!.toJson(),
      if (createdTaskIds.isNotEmpty) 'createdTaskIds': createdTaskIds,
      if (data != null) 'data': data,
      if (showBadge) 'showBadge': true,
      if (projectDraft != null) 'projectDraft': projectDraft,
    };
  }

  static String _normalizeAivyIntent(String? raw) {
    final v = (raw ?? '').trim().toLowerCase();
    const valid = {
      'job_new',
      'job_dispatch',
      'order_create',
      'order_dispatched',
      'select_order_for_dispatch',
      'manual_payment_reminder',
      'order_payment_received',
      'payment_due',
      'report_request',
      'general',
      'analytics_query',
      'total_quotation_today',
      'quotation_names_today',
      'total_orders_today',
      'dispatches_today',
      'total_orders_month',
      'quotation_value_today',
      'project_extract',
      'project_query',
      'project_today',
      'project_update',
    };
    if (valid.contains(v)) {
      return v;
    }
    return 'general';
  }

  static String _normalizeCategory(String? raw) {
    final lowered = (raw ?? '').trim().toLowerCase();
    const valid = {'client', 'work', 'personal', 'general'};
    if (valid.contains(lowered)) {
      return lowered;
    }
    return 'general';
  }

  static String _normalizeMemoryCategory(String? raw) {
    final lowered = (raw ?? '').trim().toLowerCase();
    if (lowered == 'meeting') {
      return 'note';
    }
    const valid = {
      'quotation',
      'task',
      'note',
      'general',
      'goal',
    };
    if (valid.contains(lowered)) {
      return lowered;
    }
    return 'general';
  }

  static List<String> _readStringList(Object? value) {
    if (value is! List) {
      return const [];
    }

    return value
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static List<FollowUpSuggestion> _readFollowUps(Object? value) {
    if (value is! List) {
      return const [];
    }

    return value
        .whereType<Map>()
        .map(
          (item) =>
              FollowUpSuggestion.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false);
  }

  static List<ReminderSuggestion> _readReminders(Object? value) {
    if (value is! List) {
      return const [];
    }

    return value
        .whereType<Map>()
        .map(
          (item) =>
              ReminderSuggestion.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false);
  }

}

class PgplJobRecord {
  const PgplJobRecord({
    required this.client,
    required this.amount,
    required this.status,
    required this.invoiceAmount,
  });

  final String client;
  final double amount;
  final String status;
  final double invoiceAmount;

  const PgplJobRecord.empty()
    : client = '',
      amount = 0,
      status = 'pending',
      invoiceAmount = 0;

  factory PgplJobRecord.fromJson(Object? raw) {
    if (raw is! Map) {
      return const PgplJobRecord.empty();
    }
    final m = Map<String, dynamic>.from(raw);
    final statusRaw = (m['status'] as String? ?? 'pending').trim().toLowerCase();
    final status = statusRaw == 'dispatched' ? 'dispatched' : 'pending';
    return PgplJobRecord(
      client: (m['client'] as String? ?? '').trim(),
      amount: readAmount(m['amount']),
      status: status,
      invoiceAmount: readAmount(
        m['invoiceAmount'],
        fallback: readAmount(m['amount']),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'client': client,
    'amount': amount,
    'status': status,
    'invoiceAmount': invoiceAmount,
  };

  static double readAmount(Object? v, {double fallback = 0}) {
    if (v is num) {
      return v.toDouble();
    }
    final parsed = double.tryParse(v?.toString() ?? '');
    if (parsed != null) {
      return parsed;
    }
    return fallback;
  }
}

class PgplPaymentRecord {
  const PgplPaymentRecord({
    required this.client,
    required this.amount,
    required this.dueDateIso,
  });

  final String client;
  final double amount;
  final String dueDateIso;

  const PgplPaymentRecord.empty()
    : client = '',
      amount = 0,
      dueDateIso = '';

  factory PgplPaymentRecord.fromJson(Object? raw) {
    if (raw is! Map) {
      return const PgplPaymentRecord.empty();
    }
    final m = Map<String, dynamic>.from(raw);
    return PgplPaymentRecord(
      client: (m['client'] as String? ?? '').trim(),
      amount: PgplJobRecord.readAmount(m['amount']),
      dueDateIso: (m['dueDateIso'] as String? ?? '').trim(),
    );
  }

  Map<String, dynamic> toJson() => {
    'client': client,
    'amount': amount,
    'dueDateIso': dueDateIso,
  };
}

class GoalRecord {
  const GoalRecord({
    required this.title,
    required this.targetAmount,
    required this.currency,
    required this.period,
    required this.monthKey,
  });

  final String title;
  final double targetAmount;
  final String currency;
  final String period;
  final String monthKey;

  static GoalRecord? tryFromJson(Map<String, dynamic> json) {
    final amount = json['targetAmount'];
    final num? n = amount is num ? amount : num.tryParse('$amount');
    if (n == null || n <= 0) {
      return null;
    }
    var monthKey = (json['monthKey'] as String? ?? '').trim();
    if (!RegExp(r'^\d{4}-\d{2}$').hasMatch(monthKey)) {
      return null;
    }
    final title = (json['title'] as String? ?? '').trim().isEmpty
        ? 'Monthly target'
        : (json['title'] as String).trim();
    final currency = (json['currency'] as String? ?? 'INR').trim();
    final period = (json['period'] as String? ?? 'month').trim();
    return GoalRecord(
      title: title,
      targetAmount: n.toDouble(),
      currency: currency.isEmpty ? 'INR' : currency,
      period: period.isEmpty ? 'month' : period,
      monthKey: monthKey,
    );
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'targetAmount': targetAmount,
    'currency': currency,
    'period': period,
    'monthKey': monthKey,
  };
}

class FollowUpSuggestion {
  const FollowUpSuggestion({required this.when, required this.reason});

  final String when;
  final String reason;

  factory FollowUpSuggestion.fromJson(Map<String, dynamic> json) {
    return FollowUpSuggestion(
      when: (json['when'] as String? ?? '').trim(),
      reason: (json['reason'] as String? ?? '').trim(),
    );
  }

  Map<String, dynamic> toJson() {
    return {'when': when, 'reason': reason};
  }
}

class ReminderSuggestion {
  const ReminderSuggestion({
    required this.title,
    required this.timeHint,
    required this.priority,
    this.scheduledAtIso,
    this.isAutoGenerated = false,
    this.reminderType,
    this.orderId,
    this.orderAmountInr,
    this.displayClientName,
    this.note,
    this.paymentId,
  });

  final String title;
  final String timeHint;
  final String priority;
  final String? scheduledAtIso;
  final bool isAutoGenerated;
  final String? reminderType;
  final String? orderId;
  final double? orderAmountInr;
  final String? displayClientName;
  final String? note;
  final String? paymentId;

  factory ReminderSuggestion.fromJson(Map<String, dynamic> json) {
    final scheduledAtIsoRaw = (json['scheduledAtIso'] as String?)?.trim() ?? '';
    final autoRaw = json['isAutoGenerated'];
    final isAuto = autoRaw == true || autoRaw == 'true';
    final amtRaw = json['orderAmountInr'];
    double? orderAmt;
    if (amtRaw is num) {
      orderAmt = amtRaw.toDouble();
    } else if (amtRaw is String) {
      orderAmt = double.tryParse(amtRaw);
    }
    return ReminderSuggestion(
      title: (json['title'] as String? ?? '').trim(),
      timeHint: (json['timeHint'] as String? ?? '').trim(),
      priority: (json['priority'] as String? ?? 'medium').trim(),
      scheduledAtIso: scheduledAtIsoRaw.isEmpty ? null : scheduledAtIsoRaw,
      isAutoGenerated: isAuto,
      reminderType: (json['reminderType'] as String?)?.trim(),
      orderId: (json['orderId'] as String?)?.trim(),
      orderAmountInr: orderAmt,
      displayClientName: (json['displayClientName'] as String?)?.trim(),
      note: (json['note'] as String?)?.trim(),
      paymentId: (json['paymentId'] as String?)?.trim(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'timeHint': timeHint,
      'priority': priority,
      'scheduledAtIso': scheduledAtIso,
      if (isAutoGenerated) 'isAutoGenerated': true,
      if (reminderType != null) 'reminderType': reminderType,
      if (orderId != null) 'orderId': orderId,
      if (orderAmountInr != null) 'orderAmountInr': orderAmountInr,
      if (displayClientName != null) 'displayClientName': displayClientName,
      if (note != null) 'note': note,
      if (paymentId != null) 'paymentId': paymentId,
    };
  }
}
