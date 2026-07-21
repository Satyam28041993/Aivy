import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint, kDebugMode;
import 'package:intl/intl.dart';

import '../../clients/data/client_repository.dart';
import '../../clients/models/client.dart';
import '../../contacts/application/whatsapp_contact_intent_parser.dart';
import '../../contacts/data/contact_service.dart';
import '../../dashboard/models/order_record.dart';
import '../../payments/data/payment_repository.dart';
import '../../payments/models/payment_record.dart';
import '../../reminders/data/reminder_repository.dart';
import '../../reminders/utils/reminder_time_parser.dart';
import '../../structured_actions/data/structured_action_repository.dart';
import '../../structured_actions/models/structured_action.dart';
import '../../structured_actions/utils/name_normalize.dart';
import '../data/chat_flow_state.dart';
import '../data/chat_repository.dart';
import '../data/chat_state_service.dart';
import 'confirm_payload_mapper.dart';
import '../utils/intent_detection.dart' show AivyUserIntent, detectIntent;
import '../utils/payment_line_parser.dart';
import 'flow_catalog.dart';
import 'flow_formatters.dart'
    show formatConfirmSummary, formatPaymentSummary, getGreeting;
import 'flow_save_router.dart' as flow_save;
import 'flow_step_engine.dart';
import '../utils/inline_confirm_edit.dart';
import '../utils/payment_received_trigger.dart'
    show
        detectPaymentReceivedWithNameDetails,
        hasPaymentReceivedIntentText;
import '../utils/smart_command_expand.dart';
import '../utils/aivy_response_formatter.dart' show capitalizeWords;
import '../utils/conversational_date_parser.dart';
import '../utils/extract_inr_amount.dart';
import '../utils/task_reminder_parser.dart';
import '../../whatsapp/data/whatsapp_inbox_repository.dart';
import '../../whatsapp/utils/whatsapp_outbound_text.dart';
import '../../integrations/data/google_integration_store.dart';
import '../../integrations/google/google_calendar_client.dart';
import '../../integrations/google/google_calendar_intent_parser.dart';
import '../../integrations/google/google_gmail_client.dart';
import '../../integrations/google/google_gmail_intent_parser.dart';
import '../../integrations/google/google_sheets_client.dart';
import '../../integrations/google/google_sheets_intent_parser.dart';

/// Outcome of [ControlledChatFlow.process] before greeting / cloud fallback.
enum ProcessKind {
  none,
  assistantOnly,
  openCategorySheet,
  /// In-chat confirm with quick replies (replaces modal for wizard).
  inChatConfirm,
  /// Legacy modal path; coordinator can treat as [inChatConfirm].
  openConfirmDialog,
  disambiguation,
  cloud,
}

class ProcessResult {
  const ProcessResult._({
    required this.kind,
    this.assistantMessage,
    this.confirmDraft,
    this.confirmDraftMap,
    this.disambiguationLine,
    this.option1,
    this.option2,
    this.cloudText,
    this.cloudIntent,
    this.aivyData,
  });

  const ProcessResult.none() : this._(kind: ProcessKind.none);

  const ProcessResult.assistantOnly(
    String msg, {
    Map<String, dynamic>? aivyData,
  }) : this._(
         kind: ProcessKind.assistantOnly,
         assistantMessage: msg,
         aivyData: aivyData,
       );

  const ProcessResult.categoryFlow(String assistant)
    : this._(
        kind: ProcessKind.openCategorySheet,
        assistantMessage: assistant,
      );

  const ProcessResult.inChatConfirm(
    StructuredAction draft, {
    required String summary,
    String? assistant,
    Map<String, dynamic>? aivyData,
    Map<String, dynamic>? confirmDraftMap,
  }) : this._(
         kind: ProcessKind.inChatConfirm,
         confirmDraft: draft,
         confirmDraftMap: confirmDraftMap,
         assistantMessage: summary,
         aivyData: aivyData,
       );

  const ProcessResult.confirm(StructuredAction draft, {String? assistant})
    : this._(
        kind: ProcessKind.openConfirmDialog,
        confirmDraft: draft,
        assistantMessage: assistant,
      );

  const ProcessResult.disambig(String line, String o1, String o2)
    : this._(
        kind: ProcessKind.disambiguation,
        disambiguationLine: line,
        option1: o1,
        option2: o2,
        assistantMessage: line,
      );

  const ProcessResult.cloudRun(String text, {String? intent})
    : this._(
        kind: ProcessKind.cloud,
        cloudText: text,
        cloudIntent: intent,
      );

  final ProcessKind kind;
  final String? assistantMessage;
  final StructuredAction? confirmDraft;
  /// Full Firestore-ready map (includes [flowCategoryId], [time], etc.).
  final Map<String, dynamic>? confirmDraftMap;
  final String? disambiguationLine;
  final String? option1;
  final String? option2;
  final String? cloudText;
  final String? cloudIntent;
  final Map<String, dynamic>? aivyData;

  bool get handled => kind != ProcessKind.none;
}

class ControlledChatFlow {
  ControlledChatFlow({
    ChatStateService? chatState,
    StructuredActionRepository? structuredActions,
    ChatRepository? ledgerRepository,
    flow_save.FlowSaveRouter? saveRouter,
    this.waLineTranslator,
  })  : _state = chatState ?? ChatStateService(),
        _structured = structuredActions ?? StructuredActionRepository() {
    _clients = ClientRepository();
    _payments = PaymentRepository(clients: _clients, structured: _structured);
    _reminders = ReminderRepository();
    _orders = ledgerRepository ?? ChatRepository();
    _saveRouter = saveRouter ??
        flow_save.FlowSaveRouter(
          structured: _structured,
          payments: _payments,
          ledger: _orders,
        );
    _contactBook = ContactService();
    _waOut = WhatsAppInboxRepository();
  }

  final ChatStateService _state;
  final StructuredActionRepository _structured;
  late final ClientRepository _clients;
  late final PaymentRepository _payments;
  late final ReminderRepository _reminders;
  late final ChatRepository _orders;
  late final flow_save.FlowSaveRouter _saveRouter;
  late final ContactService _contactBook;
  late final WhatsAppInboxRepository _waOut;

  final ValueNotifier<bool> confirmSaveBusy = ValueNotifier<bool>(false);

  /// Optional: Gemini English preview for WhatsApp template flow (Chat screen).
  final Future<String> Function(String line)? waLineTranslator;

  ChatStateService get stateService => _state;
  StructuredActionRepository get structuredRepository => _structured;

  bool _confirmSaveLocked = false;

  /// Mirrors Firestore `pendingData` for payment settlement when reads lag (web cache).
  final Map<String, Map<String, dynamic>> _settlementPendingMemory = {};

  void _stashSettlementPending(
    String userId,
    Map<String, dynamic> data,
  ) {
    _settlementPendingMemory[userId] = Map<String, dynamic>.from(data);
  }

  void _forgetSettlementPending(String userId) {
    _settlementPendingMemory.remove(userId);
  }

  Map<String, dynamic> _mergedSettlementPending(
    String userId,
    Map<String, dynamic> fromServer,
  ) {
    final mem = _settlementPendingMemory[userId];
    // Later map wins — in-memory stash from this device survives stale Firestore
    // snapshots (especially web) until the settlement write catches up.
    return <String, dynamic>{
      ...fromServer,
      if (mem != null) ...mem,
    };
  }

  bool _settlementRoutingRepairBlocked(ChatFlowState flow) {
    final p = flow.pendingAction;
    if (p == ChatFlowState.actionAwaitingChatConfirm ||
        p == ChatFlowState.actionAwaitingContinue ||
        p == ChatFlowState.actionEditingConfirm) {
      return true;
    }
    if (p == ChatFlowState.actionCategoryMenu ||
        p == ChatFlowState.actionSelectingSub) {
      return !_settlementPendingMemory.values.any((mem) {
        final amt = (mem['settlementReceivedAmount'] as num?)?.toDouble();
        return amt != null && amt > 0;
      });
    }
    return false;
  }

  bool _hasActiveSettlementInMemory(String userId) {
    final mem = _settlementPendingMemory[userId];
    if (mem == null) return false;
    final amt = (mem['settlementReceivedAmount'] as num?)?.toDouble();
    final cid = (mem['settlementClientId'] as String? ?? '').trim();
    final nm = (mem['settlementDisplayName'] as String? ?? '').trim();
    return amt != null && amt > 0 && cid.isNotEmpty && nm.isNotEmpty;
  }

  Future<ChatFlowState> _forceRepairSettlementFromMemory(
    String userId,
    ChatFlowState flow,
  ) async {
    final mem = _settlementPendingMemory[userId];
    if (mem == null) return flow;
    final merged = <String, dynamic>{...flow.pendingData, ...mem};
    final repaired = _stateForPaymentSettlementDateStep(flow, merged);
    _logSettlementRouteRepair('force_repair_from_memory', flow, repaired);
    await _state.updateState(userId, repaired);
    return repaired;
  }

  bool _settlementPendingDataUnequal(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    const keys = <String>{
      'settlementReceivedAmount',
      'settlementClientId',
      'settlementDisplayName',
      'settlementLinkedPaymentId',
      'settlementStructuredLegacyId',
      'settlementDueRemaining',
      'settlementInvoiceLabel',
    };
    for (final k in keys) {
      if ('${a[k]}' != '${b[k]}') {
        return true;
      }
    }
    return false;
  }

  ChatFlowState _stateForPaymentSettlementDateStep(
    ChatFlowState base,
    Map<String, dynamic> merged,
  ) {
    return ChatFlowState(
      currentCategory: base.currentCategory ?? 'payment',
      currentSubcategory: base.currentSubcategory ?? 'received',
      flowCategoryId:
          base.flowCategoryId ?? flowCategoryIdFor('payment', 'received'),
      pendingAction: ChatFlowState.actionAwaitingPaymentSettlementDate,
      stepIndex: 0,
      pendingData: merged,
      pendingSelection: base.pendingSelection,
      selectionType: base.selectionType,
      selectionList: base.selectionList,
      lastActionId: base.lastActionId,
      lastActionType: base.lastActionType,
      lastEntity: base.lastEntity,
    );
  }

  void _logSettlementRouteRepair(String verb, ChatFlowState before, ChatFlowState after) {
    if (!kDebugMode) {
      return;
    }
    debugPrint(
      '[AIVY_ROUTE] $verb wasAction=${before.pendingAction} nowAction=${after.pendingAction} '
      'wasStep=${before.stepIndex} nowStep=${after.stepIndex}',
    );
  }

  void _logCloudFallbackBlockCheck(String label, ChatFlowState flow) {
    if (!kDebugMode) {
      return;
    }
    // ignore: avoid_print
    print(
      '[AIVY_ROUTE] CLOUD_FALLBACK_BLOCK_CHECK $label '
      'pa=${flow.pendingAction} step=${flow.stepIndex} '
      'cat=${flow.currentCategory} sub=${flow.currentSubcategory}',
    );
  }

  /// Persists corrective routing when settlement amount is already captured but
  /// [pendingAction] lags behind (Firestore race) or is wrong/null so date
  /// replies are not mistaken for idle chat / cloud intents.
  Future<ChatFlowState> _repairPaymentSettlementRoutingIfNeeded(
    String userId,
    ChatFlowState flow,
  ) async {
    if (_settlementRoutingRepairBlocked(flow)) {
      return flow;
    }
    final merged = _mergedSettlementPending(userId, flow.pendingData);
    final received = (merged['settlementReceivedAmount'] as num?)?.toDouble();
    final cid = (merged['settlementClientId'] as String? ?? '').trim();
    final nm = (merged['settlementDisplayName'] as String? ?? '').trim();
    if (received == null || received <= 0 || cid.isEmpty || nm.isEmpty) {
      return flow;
    }
    final onDate =
        flow.pendingAction ==
        ChatFlowState.actionAwaitingPaymentSettlementDate;
    final repaired = _stateForPaymentSettlementDateStep(flow, merged);
    _stashSettlementPending(userId, merged);
    final mustPersist =
        !onDate || _settlementPendingDataUnequal(flow.pendingData, merged);
    if (mustPersist) {
      _logSettlementRouteRepair('settlement_receive_date_prioritize', flow, repaired);
      await _state.updateState(userId, repaired);
      return repaired;
    }
    return repaired;
  }

  static bool isCategoryTrigger(String raw) {
    final s = raw.trim();
    if (s.isEmpty) {
      return false;
    }
    if (s.startsWith('+')) {
      return true;
    }
    final lower = s.toLowerCase();
    if (lower == 'aivy') {
      return true;
    }
    if (RegExp(
      r'^(hi|hello|hey)\s+aivy\b',
      caseSensitive: false,
    ).hasMatch(s)) {
      return true;
    }
    if (RegExp(r'^aivy\b', caseSensitive: false).hasMatch(lower)) {
      return true;
    }
    return false;
  }

  /// Session has an active controlled-flow step ([pendingAction] non-empty and
  /// not [ChatFlowState.actionIdle]) — generic cloud chat must not intercept.
  static bool isControlledFlowBlockingGenericAi(ChatFlowState flow) {
    final p = flow.pendingAction?.trim();
    if (p == null || p.isEmpty) {
      return false;
    }
    return p != ChatFlowState.actionIdle;
  }

  /// Payment wizards ([actionAwaitingPaymentReceivedChoice], etc.) should not swallow
  /// "aaj kise call karna"–style questions — those belong on the cloud analytics path.
  static bool _looksLikeFollowupOrCallListQuestion(String raw) {
    final low = raw.toLowerCase().trim();
    if (low.length < 8) {
      return false;
    }
    if (expandSmartCommandInput(raw) != null) {
      return true;
    }
    final hasTime = RegExp(
      r'\b(aaj|today|kal|yesterday|is\s*hafte|this\s*week|abhi)\b',
    ).hasMatch(low);
    final hasCall = RegExp(
      r'\b(call|phone|ring|mil\b|milan|follow[\s-]?up|followup|vasool)\b',
    ).hasMatch(low);
    final hasWhom = RegExp(
      r'\b(kise|kis\s*ko|kisko|kaun|kaun\s*sa|kaun\s*si|who|whom|mujhe\s+kise|mujhe\s+kis)\b',
    ).hasMatch(low);
    final asksGuidance = RegExp(
      r'\b(batao|bata|bataye|list|dikhao|dikha|chahiye|puch|pooch|bataiy)\b',
    ).hasMatch(low);
    final hasKarna = RegExp(r'\bkarna\b').hasMatch(low);
    if (hasCall && hasWhom && (hasTime || asksGuidance || hasKarna)) {
      return true;
    }
    if (hasTime &&
        RegExp(r'\b(follow|followup|follow-up|vasool|collection)\b').hasMatch(low) &&
        (asksGuidance ||
            RegExp(r'\b(kise|kisko|kaun|list)\b').hasMatch(low))) {
      return true;
    }
    return false;
  }

  static bool _matchesFullPendingListUserReply(String low) {
    if (low == '1') {
      return true;
    }
    if (low == 'list' || low == 'full list' || low == 'puri list') {
      return true;
    }
    if (low.contains('dikhao') || low.contains('dikha')) {
      return true;
    }
    if (low.contains('saari') ||
        low.contains('sabki') ||
        low.contains('poori') ||
        low.contains('puri')) {
      return true;
    }
    if ((low.contains('poora') || low.contains('pura')) && low.contains('list')) {
      return true;
    }
    return false;
  }

  bool _shouldDeferPaymentDueNameToCloud(String t) {
    if (detectIntent(t) == AivyUserIntent.query) {
      return true;
    }
    final low = t.toLowerCase().trim();
    final words = low.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).length;
    if (words == 1 &&
        RegExp(
          r'^(overdue|pending|status|follow|report|analytics|business)$',
          caseSensitive: false,
        ).hasMatch(low)) {
      return true;
    }
    if (words < 2) {
      return false;
    }
    return RegExp(
      r'\b(highest|top|overdue|pending|amount|clients?|payment|status|follow'
      r'|list|kitna|kitne|baki|baaki|dues?|report|business|vasool|collection)\b',
      caseSensitive: false,
    ).hasMatch(low);
  }

  bool _isPaymentDueNameFlowCancel(String low) {
    return low == 'cancel' ||
        low == 'band' ||
        low == 'stop' ||
        low == 'exit' ||
        low == 'nahi' ||
        low == 'back' ||
        low == 'chhodo' ||
        low == 'bas';
  }

  void _log(String label, Object? o) {
    // ignore: avoid_print
    print('AIVY_CTRL $label: $o');
  }

  static String? _reminderSubFromFlowCategoryId(String fcid) {
    if (!fcid.startsWith('reminder_')) {
      return null;
    }
    return fcid.substring('reminder_'.length);
  }

  /// Ends any in-progress controlled flow (not in-chat Confirm, not Yes/Cancel continue).
  static bool _isBroadFlowCancel(String t) {
    final low = t.toLowerCase().trim();
    if (low.isEmpty) {
      return false;
    }
    return low == 'cancel' ||
        low == 'band' ||
        low == 'exit' ||
        low == 'quit' ||
        low == 'stop' ||
        (low.startsWith('cancel ') && low.length < 40) ||
        (low.contains('flow') && low.contains('band'));
  }

  static bool _isUndoCommand(String t) {
    final low = t.toLowerCase().trim();
    if (low.isEmpty) {
      return false;
    }
    return low == 'undo' ||
        low == 'undoo' ||
        low == 'last undo' ||
        low.contains('galti ho gayi') ||
        low == 'galti' ||
        low == 'galat' ||
        (low.contains('undo') && low.length < 20);
  }

  Future<ProcessResult> _tryUndo(
    String userId,
    ChatFlowState flow,
  ) async {
    final id = flow.lastActionId;
    if (id == null || id.isEmpty) {
      return const ProcessResult.assistantOnly('Koi last action undo ke liye nahi mila.');
    }
    final typ = flow.lastActionType ?? '';
    if (typ == 'reminder_created') {
      await ReminderRepository().deleteReminder(userId, id);
      _log('UNDO', {'id': id, 'op': 'reminder_delete'});
    } else if (typ == 'created') {
      await _structured.revertAction(userId, id);
      _log('UNDO', {'id': id, 'op': 'reverted'});
    } else if (typ == 'payment_receipt') {
      await _payments.undoReceipt(userId, id);
      _log('UNDO', {'id': id, 'op': 'payment_receipt_undo'});
    } else if (typ == 'payment_due_created') {
      final data = await _payments.readDoc(userId, id);
      final clientId = (data?['clientId'] as String? ?? '').trim();
      final amount = (data?['amount'] as num?)?.toDouble() ?? 0.0;
      await _payments.deleteById(userId, id);
      if (clientId.isNotEmpty && amount > 0) {
        await _clients.adjustOutstanding(userId, clientId, -amount);
      }
      _log('UNDO', {'id': id, 'op': 'payment_due_delete'});
    } else if (typ == 'status_completed') {
      await _structured.setStatus(userId, id, 'pending');
      _log('UNDO', {'id': id, 'op': 'revert_status'});
    } else {
      return const ProcessResult.assistantOnly('Last action type unknown — skip.');
    }
    await _state.clearLastActionRecord(userId);
    return const ProcessResult.assistantOnly('Last action undone.');
  }

  static Map<String, dynamic> draftToMap(StructuredAction a) {
    return {
      'type': a.type,
      'subType': a.subType,
      'name': a.name,
      'nameLower': a.nameLower.isNotEmpty
          ? a.nameLower
          : (a.name.isNotEmpty ? normalizeName(a.name) : ''),
      'amount': a.amount,
      'date': a.date?.millisecondsSinceEpoch,
      'note': a.note,
      'id': a.id,
      'status': a.status,
      if (a.title != null && a.title!.trim().isNotEmpty) 'title': a.title,
      if (a.clientId != null && a.clientId!.trim().isNotEmpty)
        'clientId': a.clientId,
      if (a.linkedPaymentId != null && a.linkedPaymentId!.trim().isNotEmpty)
        'linkedPaymentId': a.linkedPaymentId,
    };
  }

  static Map<String, dynamic> buildConfirmDraftMap(
    StructuredAction draft, {
    required String flowCategoryId,
    Map<String, dynamic>? stepData,
  }) {
    final o = Map<String, dynamic>.from(draftToMap(draft));
    o['flowCategoryId'] = flowCategoryId;
    if (stepData != null) {
      final tv = stepData[FlowStepEngine.kTime] ?? stepData['time'];
      if (tv is int) {
        o[FlowStepEngine.kTime] = tv;
        o['time'] = tv;
      }
      if (stepData['timeSkipped'] == true) {
        o['timeSkipped'] = true;
      }
      for (final k in [
        'taskTitle',
        'clientName',
        'birthDate',
        'priority',
        'clientId',
        'linkedPaymentId',
        'quotationId',
        'title',
      ]) {
        if (stepData.containsKey(k)) {
          o[k] = stepData[k];
        }
      }
    }
    return o;
  }

  static StructuredAction draftFromMap(Map<String, dynamic> m) =>
      flow_save.draftFromMapForSave(m);

  Future<ProcessResult> process({
    required String userId,
    required String text,
  }) async {
    _log('INPUT', text);
    var flow = await _state.getState(userId);
    flow = await _repairPaymentSettlementRoutingIfNeeded(userId, flow);
    if (kDebugMode) {
      debugPrint(
        '[AIVY_ROUTE] after_repair text="${text.trim()}" '
        'pendingAction=${flow.pendingAction} cat=${flow.currentCategory} '
        'sub=${flow.currentSubcategory} stepIndex=${flow.stepIndex} '
        'flowCategoryId=${flow.flowCategoryId}',
      );
    }
    _log('STATE', {
      'cat': flow.currentCategory,
      'sub': flow.currentSubcategory,
      'action': flow.pendingAction,
      'step': flow.stepIndex,
      'data': flow.pendingData,
      'sel': flow.pendingSelection,
      'last': flow.lastActionId,
      'flowCategoryId': flow.flowCategoryId,
      'lastEntity': flow.lastEntity,
    });
    var t = text.trim();
    if (flow.pendingAction == ChatFlowState.actionCategoryMenu) {
      if (isCategoryTrigger(t)) {
        await _state.updateState(
          userId,
          const ChatFlowState(
            pendingAction: ChatFlowState.actionCategoryMenu,
            pendingData: {},
            stepIndex: 0,
          ),
        );
        return ProcessResult.categoryFlow(getGreeting());
      }
      if (t.isNotEmpty) {
        if (_hasActiveSettlementInMemory(userId)) {
          flow = await _forceRepairSettlementFromMemory(userId, flow);
        } else {
          await _state.clearState(userId);
          _forgetSettlementPending(userId);
          flow = const ChatFlowState();
        }
      }
    }
    if (flow.pendingAction == ChatFlowState.actionSelectingSub) {
      if (isCategoryTrigger(t)) {
        await _state.updateState(
          userId,
          const ChatFlowState(
            pendingAction: ChatFlowState.actionCategoryMenu,
            pendingData: {},
            stepIndex: 0,
          ),
        );
        return ProcessResult.categoryFlow(getGreeting());
      }
      if (t.isNotEmpty) {
        if (_hasActiveSettlementInMemory(userId)) {
          flow = await _forceRepairSettlementFromMemory(userId, flow);
        } else {
          await _state.clearState(userId);
          _forgetSettlementPending(userId);
          flow = const ChatFlowState();
        }
      }
    }

    flow = await _repairPaymentSettlementRoutingIfNeeded(userId, flow);

    t = text.trim();
    final allowEmptyPaymentReceiveDate =
        flow.pendingAction ==
        ChatFlowState.actionAwaitingPaymentSettlementDate;
    if (t.isEmpty && !allowEmptyPaymentReceiveDate) {
      _logCloudFallbackBlockCheck('empty_input_early_exit', flow);
      return const ProcessResult.none();
    }

    if (_isUndoCommand(t)) {
      return await _tryUndo(userId, flow);
    }

    if (_isBroadFlowCancel(t) &&
        flow.pendingAction != null &&
        flow.pendingAction != ChatFlowState.actionAwaitingChatConfirm &&
        flow.pendingAction != ChatFlowState.actionAwaitingContinue &&
        flow.pendingAction != ChatFlowState.actionCategoryMenu &&
        flow.pendingAction != ChatFlowState.actionSelectingSub &&
        flow.pendingAction !=
            ChatFlowState.actionAwaitingWhatsappContactConfirm &&
        flow.pendingAction != ChatFlowState.actionAwaitingWhatsappLangPick) {
      await _state.clearState(userId);
      _forgetSettlementPending(userId);
      return const ProcessResult.assistantOnly(
        'Theek — flow band. Jo likhna ho type karein.',
      );
    }

    if (flow.pendingAction ==
        ChatFlowState.actionAwaitingPaymentSettlementDate) {
      final dateResult = await _handlePaymentReceivedDate(userId, t, flow);
      return dateResult;
    }

    if (flow.pendingAction ==
        ChatFlowState.actionAwaitingWhatsappContactConfirm) {
      return _handleWhatsappContactConfirm(userId, t, flow);
    }
    if (flow.pendingAction == ChatFlowState.actionAwaitingWhatsappLangPick) {
      return _handleWhatsappLangPick(userId, t, flow);
    }
    if (flow.pendingAction == ChatFlowState.actionAwaitingWhatsappSendMessage) {
      return _handleAwaitingWhatsappSendMessage(userId, t, flow);
    }
    if (flow.pendingAction == ChatFlowState.actionAwaitingWhatsappPhoneNumber) {
      return _handleAwaitingWhatsappPhoneNumber(userId, t, flow);
    }

    // ---- In-chat confirm (Confirm / Edit / Cancel) ----
    if (flow.pendingAction == ChatFlowState.actionAwaitingChatConfirm) {
      return _handleChatConfirm(userId, t, flow);
    }

    if (flow.pendingAction == ChatFlowState.actionAwaitingCreateClientConfirm) {
      return _handleAwaitingCreateClientConfirm(userId, t, flow);
    }

    if (flow.pendingAction == ChatFlowState.actionAwaitingNewClientName) {
      return _handleAwaitingNewClientName(userId, t, flow);
    }

    if (flow.pendingAction == ChatFlowState.actionAwaitingPaymentReceivedChoice) {
      return _handlePaymentReceivedChoice(userId, t, flow);
    }

    if (flow.pendingAction == ChatFlowState.actionAwaitingPaymentReceivedClientName) {
      return _handlePaymentReceivedClientName(userId, t, flow);
    }

    if (flow.pendingAction ==
        ChatFlowState.actionAwaitingPaymentSettlementAmount) {
      return _handlePaymentSettlementAmount(userId, t, flow);
    }

    if (flow.pendingAction == ChatFlowState.actionAwaitingPaymentDueChoice) {
      return _handlePaymentDueChoice(userId, t, flow);
    }
    if (flow.pendingAction == ChatFlowState.actionAwaitingPaymentDueClientName) {
      return _handlePaymentDueClientName(userId, t, flow);
    }

    // ---- Payment Follow-up flow ----
    if (flow.pendingAction ==
        ChatFlowState.actionAwaitingPaymentFollowupChoice) {
      return _handlePaymentFollowupChoice(userId, t, flow);
    }
    if (flow.pendingAction == ChatFlowState.actionAwaitingFollowupAmount) {
      return _handleFollowupAmount(userId, t, flow);
    }
    if (flow.pendingAction == ChatFlowState.actionAwaitingFollowupDate) {
      return _handleFollowupDate(userId, t, flow);
    }
    if (flow.pendingAction ==
        ChatFlowState.actionAwaitingFollowupNewClientName) {
      return _handleFollowupNewClientName(userId, t, flow);
    }
    if (flow.pendingAction == ChatFlowState.actionAwaitingOrderUpdateMode) {
      return _handleOrderUpdateMode(userId, t, flow);
    }
    if (flow.pendingAction == ChatFlowState.actionAwaitingOrderClientName) {
      return _handleOrderClientName(userId, t, flow);
    }
    if (flow.pendingAction == ChatFlowState.actionAwaitingOrderProcessStage) {
      return _handleOrderProcessStage(userId, t, flow);
    }
    if (flow.pendingAction == ChatFlowState.actionAwaitingOrderDispatchAmount) {
      return _handleOrderDispatchAmount(userId, t, flow);
    }
    if (flow.pendingAction ==
        ChatFlowState.actionAwaitingOrderDispatchDueChoice) {
      return _handleOrderDispatchDueChoice(userId, t, flow);
    }
    if (flow.pendingAction ==
        ChatFlowState.actionAwaitingOrderDispatchReceivedAmount) {
      return _handleOrderDispatchReceivedAmount(userId, t, flow);
    }
    if (flow.pendingAction ==
        ChatFlowState.actionAwaitingOrderDispatchTermDays) {
      return _handleOrderDispatchTermDays(userId, t, flow);
    }

    // ---- Continue? after unrelated interrupt ----
    if (flow.pendingAction == ChatFlowState.actionAwaitingContinue) {
      final low = t.toLowerCase();
      if (low == 'yes' || low == 'haan' || low == 'y' || low == '1') {
        final r = flow.pendingData['resume'];
        if (r is! Map) {
          await _state.clearState(userId);
          return const ProcessResult.assistantOnly('State lost — naya se “Aivy” bhejein.');
        }
        final m = Map<String, dynamic>.from(r);
        final rCat = m['cat'] as String? ?? 'payment';
        final rSub = m['sub'] as String? ?? 'received';
        final rFcid = m['flowCategoryId'] as String? ??
            flowCategoryIdFor(rCat, rSub);
        await _state.updateState(
          userId,
          ChatFlowState(
            currentCategory: rCat,
            currentSubcategory: rSub,
            flowCategoryId: rFcid,
            pendingAction: ChatFlowState.actionCollecting,
            stepIndex: (m['step'] as num?)?.toInt() ?? 0,
            pendingData: m['data'] is Map
                ? Map<String, dynamic>.from(m['data'] as Map)
                : const {},
          ),
        );
        final cat = rCat;
        final sub = rSub;
        _log('STEP', 'resumed at ${(m['step'] as num?)?.toInt() ?? 0}');
        return ProcessResult.assistantOnly(
          FlowStepEngine.getNextQuestion(
            (m['step'] as num?)?.toInt() ?? 0,
            cat,
            sub,
          ),
        );
      }
      if (low == 'cancel' || low == 'nahi' || low == 'no' || low == '2') {
        await _state.clearState(userId);
        return const ProcessResult.assistantOnly('Theek, flow band. Phir se “Aivy” bhej sakte hain.');
      }
      return const ProcessResult.assistantOnly('Reply: Yes (continue) ya Cancel (chhod do).');
    }

    // ---- Pending list selection (payment update) ----
    if (flow.pendingAction == ChatFlowState.actionPendingSelection) {
      return _handlePendingSelection(userId, t, flow);
    }

    // ---- Edit before confirm (field / value) ----
    if (flow.pendingAction == ChatFlowState.actionEditingConfirm) {
      return _handleEditing(userId, t, flow);
    }

    if (flow.pendingAction == ChatFlowState.actionAwaitingDisambig) {
      final pick = t.toLowerCase();
      String? choice;
      if (pick == '1' || pick.startsWith('1')) {
        choice = flow.pendingData['disambig1'] as String?;
      } else if (pick == '2' || pick.startsWith('2')) {
        choice = flow.pendingData['disambig2'] as String?;
      } else if (RegExp(
        r'payment|due|vasool|lena',
        caseSensitive: false,
      ).hasMatch(pick)) {
        choice = 'payment_due';
      } else if (RegExp(
        r'reminder|yaad|call',
        caseSensitive: false,
      ).hasMatch(pick)) {
        choice = 'reminder';
      }
      if (choice == 'payment_due') {
        await _state.updateState(
          userId,
          ChatFlowState(
            currentCategory: 'payment',
            currentSubcategory: 'due',
            flowCategoryId: flowCategoryIdFor('payment', 'due'),
            pendingAction: ChatFlowState.actionAwaitingPaymentDueChoice,
            stepIndex: 0,
            pendingData: const {},
          ),
        );
        return const ProcessResult.assistantOnly(
          '💰 Kya karna hai?\n\n'
          '1. Saari pending payment ki list (amount + due date)\n'
          '2. Sirf ek client ki list — pehle 2 bhejein, phir client ka naam\n\n'
          'Naya due / amount jodna ho to: Payment → Follow-up → Payment follow-up.\n\n'
          'Ya seedha client ka naam bhi likh sakte hain (uski pending list ke liye).',
        );
      }
      if (choice == 'reminder') {
        final init = FlowStepEngine.initialPendingData('reminder', 'task');
        await _state.updateState(
          userId,
          ChatFlowState(
            currentCategory: 'reminder',
            currentSubcategory: 'task',
            flowCategoryId: flowCategoryIdFor('reminder', 'task'),
            pendingAction: ChatFlowState.actionCollecting,
            stepIndex: 0,
            pendingData: init,
          ),
        );
        return ProcessResult.assistantOnly(
          FlowStepEngine.getNextQuestion(0, 'reminder', 'task'),
        );
      }
      return ProcessResult.assistantOnly(
        'Reply 1 (Payment due) or 2 (Reminder), or type payment / reminder.',
      );
    }

    if (flow.pendingAction == ChatFlowState.actionCollecting &&
        flow.currentCategory != null &&
        flow.currentSubcategory != null) {
      return _handleCollecting(userId, t, flow);
    }

    if (flow.pendingAction == null ||
        flow.pendingAction == ChatFlowState.actionIdle) {
      if (isCategoryTrigger(t)) {
        await _state.updateState(
          userId,
          const ChatFlowState(
            pendingAction: ChatFlowState.actionCategoryMenu,
            pendingData: {},
            stepIndex: 0,
          ),
        );
        _log('INTENT', 'category_menu');
        return ProcessResult.categoryFlow(getGreeting());
      }

      final recvDirect = tryParsePaymentReceivedDirect(t);
      if (recvDirect != null) {
        final res =
            await _clients.resolveForPaymentName(userId, recvDirect.clientName);
        if (res.needsCreateConfirmation) {
          return const ProcessResult.assistantOnly(
            'Koi pending due nahi mila.',
          );
        }
        if (res.needsDisambiguation) {
          final buf = StringBuffer('Kaunsa client?\n\n');
          final nameList = <Map<String, dynamic>>[];
          for (var i = 0; i < res.candidates.length; i++) {
            buf.writeln('${i + 1}. ${res.candidates[i].name}');
            nameList.add({
              'id': res.candidates[i].id,
              'name': res.candidates[i].name,
            });
          }
          await _state.updateState(
            userId,
            ChatFlowState(
              pendingAction: ChatFlowState.actionPendingSelection,
              selectionType: ChatFlowState.selectionClientPick,
              selectionList: nameList,
              pendingSelection: true,
              pendingData: {
                'clientPickResume': {
                  'directReceive': true,
                  'amount': recvDirect.amountInr,
                  'rawNote': t,
                  'flowCategoryId': 'payment_received',
                },
              },
            ),
          );
          return ProcessResult.assistantOnly(buf.toString().trim());
        }
        final c = res.client!;
        final rows = await _mergedOpenDuesForClient(userId, c);
        if (rows.isEmpty) {
          return const ProcessResult.assistantOnly(
            'Koi pending due nahi mila.',
          );
        }
        final amt = recvDirect.amountInr;
        double rowRem(Map<String, dynamic> r) {
          final x = r['remainingAmount'];
          if (x is num) {
            return x.toDouble();
          }
          return (r['amount'] as num?)?.toDouble() ?? 0.0;
        }

        final linked = rows.where((r) => rowRem(r) == amt).toList();
        Map<String, dynamic>? pick;
        if (linked.length == 1) {
          pick = linked.single;
        } else if (rows.length == 1) {
          pick = rows.single;
        }
        if (pick != null) {
          return _beginPaymentDueSettlement(userId, c, pick);
        }
        final buf = StringBuffer();
        buf.writeln(
          'Is amount (${NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0).format(amt)}) ki exact open due nahi mili — chunein:\n\n',
        );
        final sl = <Map<String, dynamic>>[];
        for (var i = 0; i < rows.length; i++) {
          buf.writeln(_formatPaymentRowLine(i + 1, rows[i]));
          sl.add(rows[i]);
        }
        buf.writeln('\nNumber bhejein (1–${rows.length}).');
        await _state.updateState(
          userId,
          ChatFlowState(
            pendingAction: ChatFlowState.actionPendingSelection,
            selectionType: ChatFlowState.selectionPaymentUpdate,
            selectionList: sl,
            pendingSelection: true,
            stepIndex: 0,
            pendingData: const {},
          ),
        );
        return ProcessResult.assistantOnly(buf.toString().trim());
      }

      final dueKo = tryParsePaymentDueKo(t);
      if (dueKo != null) {
        final due = DateTime.now().add(const Duration(days: 7));
        final draftK = StructuredAction(
          type: 'payment',
          subType: 'payment_due',
          name: dueKo.clientName,
          nameLower: dueKo.clientName.isNotEmpty
              ? normalizeName(dueKo.clientName)
              : '',
          amount: dueKo.amountInr,
          date: due,
          note: t,
          status: 'pending',
          createdAt: DateTime.now(),
        );
        final fcidK = flowCategoryIdFromActionTypes(draftK.type, draftK.subType);
        final mapK = buildConfirmDraftMap(draftK, flowCategoryId: fcidK);
        final cr = await _ensureClientForPaymentMap(
          userId,
          mapK,
          'payment',
          'due',
          fcidK,
        );
        if (cr != null) {
          return cr;
        }
        final d2 = draftFromMap(mapK);
        return ProcessResult.inChatConfirm(
          d2,
          summary: formatConfirmSummary(mapK, d2),
          confirmDraftMap: mapK,
          aivyData: _quickRepliesAivy,
        );
      }

      // Payment received + name → open payment selection (Phase 5–6: fuzzy, aliases)
      var payRes = detectPaymentReceivedWithNameDetails(t);
      if (payRes == null &&
          hasPaymentReceivedIntentText(t) &&
          flow.lastEntity != null &&
          (flow.lastEntity!['type'] as String? ?? '') == 'payment') {
        final nameFromState =
            (flow.lastEntity!['name'] as String?)?.trim() ?? '';
        if (nameFromState.isNotEmpty) {
          final n = normalizeName(nameFromState);
          if (n.isNotEmpty) {
            final fromCtx = await _tryPaymentSelectionList(
              userId,
              n,
              rawNameToken: nameFromState,
              fromContextMemory: true,
            );
            if (fromCtx != null) {
              return fromCtx;
            }
            return const ProcessResult.assistantOnly('Koi pending due nahi mila.');
          }
        }
      }
      if (payRes != null) {
        final res = await _tryPaymentSelectionList(
          userId,
          payRes.normalized,
          rawNameToken: payRes.rawName,
        );
        if (res != null) {
          return res;
        }
        return const ProcessResult.assistantOnly('Koi pending due nahi mila.');
      }

      final gws = await _tryGoogleWorkspaceIntents(userId, t);
      if (gws != null) {
        return gws;
      }

      final waContact = await _tryWhatsAppContactIntent(userId, t);
      if (waContact != null) {
        return waContact;
      }

      if (hasPaymentReceivedIntentText(t) &&
          detectPaymentReceivedWithNameDetails(t) == null) {
        await _state.updateState(
          userId,
          const ChatFlowState(
            pendingAction: ChatFlowState.actionAwaitingPaymentReceivedChoice,
            pendingData: {},
            stepIndex: 0,
          ),
        );
        return const ProcessResult.assistantOnly(
          'Kaise proceed karna hai?\n\n'
          '1. Client ka naam likhunga\n'
          '2. Pending clients ki list dikhao',
        );
      }

      if (_isAmbiguousPaymentVsReminder(t)) {
        await _state.updateState(
          userId,
          ChatFlowState(
            pendingAction: ChatFlowState.actionAwaitingDisambig,
            stepIndex: 0,
            pendingData: const {
              'disambig1': 'payment_due',
              'disambig2': 'reminder',
            },
          ),
        );
        return const ProcessResult.disambig(
          'Select action:\n\n1. Payment due\n2. Reminder',
          'Payment due',
          'Reminder',
        );
      }

      final pay = tryParseManualPaymentLine(t);
      if (pay != null) {
        final due = DateTime.now().add(Duration(days: pay.dueDaysFromToday));
        final draft = StructuredAction(
          type: 'payment',
          subType: 'payment_due',
          name: pay.clientName,
          nameLower: pay.clientName.isNotEmpty
              ? normalizeName(pay.clientName)
              : '',
          amount: pay.amountInr,
          date: due,
          note: t,
          status: 'pending',
          createdAt: DateTime.now(),
        );
        _log('INTENT', AivyUserIntent.payment.name);
        _log('FINAL_DATA', draft);
        final fcid = flowCategoryIdFromActionTypes(draft.type, draft.subType);
        final map = buildConfirmDraftMap(draft, flowCategoryId: fcid);
        final cBlock = await _ensureClientForPaymentMap(
          userId,
          map,
          'payment',
          'due',
          fcid,
        );
        if (cBlock != null) {
          return cBlock;
        }
        final dPay = draftFromMap(map);
        return ProcessResult.inChatConfirm(
          dPay,
          summary: formatConfirmSummary(map, dPay),
          confirmDraftMap: map,
          aivyData: _quickRepliesAivy,
        );
      }

      final intent = detectIntent(t);
      _log('INTENT', intent.name);
      if (intent == AivyUserIntent.query) {
        _logCloudFallbackBlockCheck('idle_branch_cloudRun_query', flow);
        return ProcessResult.cloudRun(t, intent: 'query');
      }
    }

    if (isControlledFlowBlockingGenericAi(flow)) {
      if (kDebugMode) {
        debugPrint(
          '[AIVY_ROUTE] fallback_none_blocked pa=${flow.pendingAction} text="${text.trim()}"',
        );
      }
      return const ProcessResult.assistantOnly(
        'Is step par abhi flow chal raha hai — jo sawaal seedha pucha gaya hai '
        'wahi jawab dijiye. Date: aaj / kal / parso / 5 May / dd-mm-yyyy '
        '(ya khaali chhod dein = aaj).',
      );
    }

    _logCloudFallbackBlockCheck('idle_branch_return_none_pipeline_cloud', flow);
    return const ProcessResult.none();
  }

  static const _quickRepliesAivy = {
    'quickReplies': ['Confirm', 'Edit', 'Cancel'],
    'controlledFlow': true,
  };

  static const _createClientConfirmReplies = {
    'quickReplies': ['Yes', 'No'],
    'controlledFlow': true,
  };

  Future<ProcessResult> _handleChatConfirm(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final low = t.toLowerCase().trim();
    final m = flow.pendingData['confirmDraft'];
    if (m is! Map) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('Draft nahi mila — dubara chalu karein.');
    }

    final isCmd = _isChatConfirmButton(low);
    if (!isCmd) {
      final inline = tryParseInlineEdit(t, Map<String, dynamic>.from(m));
      if (inline != null) {
        _log('INLINE_EDIT', inline);
        final merged = Map<String, dynamic>.from(m)..addAll(inline);
        final d = draftFromMap(merged);
        final sum = formatConfirmSummary(merged, d);
        await _state.updateState(
          userId,
          ChatFlowState(
            pendingAction: ChatFlowState.actionAwaitingChatConfirm,
            stepIndex: 0,
            pendingData: {'confirmDraft': merged},
          ),
        );
        return ProcessResult.inChatConfirm(
          d,
          summary: sum,
          confirmDraftMap: merged,
          aivyData: _quickRepliesAivy,
        );
      }
    }

    if (low == 'confirm' ||
        low == '1' ||
        low == 'haan' ||
        low == 'ok' ||
        low == 'yes' ||
        low.contains('save')) {
      if (_confirmSaveLocked) {
        return const ProcessResult.assistantOnly(
          'Save sync ho raha hai — ek second baad dubara try karein.',
        );
      }
      _confirmSaveLocked = true;
      confirmSaveBusy.value = true;
      try {
        final map = Map<String, dynamic>.from(m);
        ConfirmPayloadMapper.debugUserInput(t);
        ConfirmPayloadMapper.debugDraftBeforeSave(map);
        final payloadPreview = ConfirmPayloadMapper.buildLedgerPayload(
          confirmMap: map,
          lastActionType: 'confirm_click',
          savedDocId: null,
          sourceCollection: null,
        );
        ConfirmPayloadMapper.debugPayloadConfirm(payloadPreview);
        final fcid0 = (map['flowCategoryId'] as String? ?? '').trim();
        final reminderSub = _reminderSubFromFlowCategoryId(fcid0);
        if (reminderSub != null) {
          final keys = FlowStepEngine.stepKeysFor('reminder', reminderSub);
          if (!FlowStepEngine.isFlowComplete(
            keys.length,
            'reminder',
            reminderSub,
            pendingData: map,
          )) {
            _log('VALIDATION_FAIL', map);
            await _state.clearConfirmState(userId);
            _log('STATE_RESET', 'after VALIDATION_FAIL pre-save');
            return const ProcessResult.assistantOnly(
              '⚠️ Reminder data incomplete — please sahi karein.',
            );
          }
        }
        final outcome = await _saveRouter.saveInChatConfirm(
          userId: userId,
          confirmMap: map,
        );
        if (!outcome.didPersist) {
          _log('VALIDATION_FAIL', outcome.message);
          await _state.clearConfirmState(userId);
          _log('STATE_RESET', 'after save router didPersist=false');
          return ProcessResult.assistantOnly(outcome.message);
        }
        _log('FINAL_DATA', {
          'saved': outcome.lastActionId,
          'type': outcome.lastActionType,
        });
        await _state.clearConfirmState(userId);
        _log('STATE_RESET', 'confirm_saved');
        await _state.setLastActionRecord(
          userId,
          lastActionId: outcome.lastActionId!,
          lastActionType: outcome.lastActionType!,
        );
        final after = draftFromMap(map);
        final fcidEntity = (map['flowCategoryId'] as String? ?? '').trim();
        if (fcidEntity == 'payment_received' ||
            fcidEntity == 'payment_due' ||
            (after.type == 'payment' && after.name.trim().isNotEmpty)) {
          final nm = (map['name'] as String? ?? after.name).trim();
          if (nm.isNotEmpty) {
            await _state.setLastEntity(
              userId,
              name: nm,
              type: 'payment',
            );
          }
        }
        if (map['flowCategoryId'] is String &&
            (map['flowCategoryId'] as String).startsWith('reminder_')) {
          final rid = map['flowCategoryId'] as String;
          final displayName = rid == 'reminder_task'
              ? ((((map['clientName'] as String?) ?? '').trim().isNotEmpty)
                  ? (map['clientName'] as String).trim()
                  : ((map['taskTitle'] as String?) ?? '').trim())
              : after.name.trim();
          if (displayName.isNotEmpty) {
            await _state.setLastEntity(
              userId,
              name: displayName,
              type: 'reminder',
            );
          }
        }
        return ProcessResult.assistantOnly(outcome.message);
      } finally {
        _confirmSaveLocked = false;
        confirmSaveBusy.value = false;
      }
    }
    if (low == 'edit' || low == '2' || low == 'badlo') {
      final fcidEdit = (m['flowCategoryId'] as String? ?? '').trim();
      late final String editMsg;
      if (fcidEdit == 'reminder_task') {
        editMsg = 'Kya badalna hai?\n\n'
            '1. Task\n'
            '2. Deadline\n'
            '3. Priority\n'
            '4. Note\n'
            '5. Client (optional)';
      } else if (fcidEdit == 'quotation_followup' ||
          fcidEdit == 'followup_client') {
        editMsg = 'Kya badalna hai?\n\n1. Name / client\n2. Date\n3. Note';
      } else if (fcidEdit == 'personal_task') {
        editMsg = 'Kya badalna hai?\n\n1. Task\n2. Date\n3. Note';
      } else if (fcidEdit == 'personal_birthday') {
        editMsg = 'Kya badalna hai?\n\n1. Name\n2. Birthday date\n3. Note';
      } else {
        editMsg = 'Kya badalna hai?\n\n1. Name / client\n2. Amount (₹)\n3. Date\n4. Note';
      }
      await _state.updateState(
        userId,
        ChatFlowState(
          pendingAction: ChatFlowState.actionEditingConfirm,
          stepIndex: 0,
          pendingData: {
            'editingMode': 'pick',
            'editingDraft': m,
            'editingField': null,
          },
        ),
      );
      return ProcessResult.assistantOnly(editMsg);
    }
    if (low == 'cancel' || low == '3' || low == 'band') {
      await _state.clearConfirmState(userId);
      _log('STATE_RESET', 'cancel');
      return const ProcessResult.assistantOnly('Cancel — kuch save nahi hua.');
    }
    return ProcessResult.assistantOnly(
      'Reply: Confirm, Edit, ya Cancel — ya quick buttons use karein.',
      aivyData: _quickRepliesAivy,
    );
  }

  static bool _isChatConfirmButton(String low) {
    return low == 'confirm' ||
        low == '1' ||
        low == 'haan' ||
        low == 'ok' ||
        low == 'yes' ||
        low.contains('save') ||
        low == 'edit' ||
        low == '2' ||
        low == 'badlo' ||
        low == 'cancel' ||
        low == '3' ||
        low == 'band';
  }

  Future<ProcessResult> _handlePendingSelection(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    if (flow.selectionType == ChatFlowState.selectionContactWhatsApp) {
      return _handleContactWhatsappPick(userId, t, flow);
    }
    if (flow.selectionType == ChatFlowState.selectionClientPick) {
      return _handleClientPick(userId, t, flow);
    }
    if (flow.selectionType == ChatFlowState.selectionOrderProcessPick ||
        flow.selectionType == ChatFlowState.selectionOrderDispatchPick ||
        flow.selectionType == ChatFlowState.selectionOrderClientPick) {
      return _handleOrderPendingSelection(userId, t, flow);
    }
    if (flow.selectionType == ChatFlowState.selectionPaymentNameDisambig) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly(
        'Flow reset — dubara payment received try karein.',
      );
    }
    if (flow.selectionType == ChatFlowState.selectionQuotationFollowupPick) {
      return _handleQuotationFollowupPick(userId, t, flow);
    }
    final list = flow.selectionList;
    if (list.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('List khaali — dubara try karein.');
    }
    final idx = _selectionIndexFromText(t, list.length);
    if (idx == null) {
      return ProcessResult.assistantOnly(
        '1 se ${list.length} number, pehla/dusra/last, ya "first" / "dusra" / "last" bhejein.',
      );
    }
    final row = list[idx];
    var clientId =
        (row['clientId'] as String? ??
                flow.pendingData['clientId'] as String? ??
                '')
            .trim();
    if (clientId.isEmpty) {
      final hint = (row['name'] as String? ?? '').trim();
      if (hint.length >= 2) {
        final all = await _clients.listAll(userId);
        for (final cl in all) {
          if (cl.name.toLowerCase() == hint.toLowerCase()) {
            clientId = cl.id;
            break;
          }
        }
      }
    }
    if (clientId.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly(
        'Client link nahi mila — pehle client naam se record banayein.',
      );
    }
    final c = await _clients.getById(userId, clientId);
    if (c == null) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('Client nahi mila.');
    }
    final fq = (flow.pendingData['fuzzyQuery'] as String? ?? '').trim();
    final nStr = (row['name'] as String? ?? c.name);
    final nLowerResolved = (row['nameLower'] as String? ?? '').trim().isNotEmpty
        ? (row['nameLower'] as String).trim()
        : normalizeName(nStr);
    if (fq.isNotEmpty && nLowerResolved.isNotEmpty) {
      await _maybeAppendShortAliasForUser(
        userId,
        nameLower: nLowerResolved,
        shortQuery: fq,
      );
    }
    await _state.clearState(userId);
    if (nStr.isNotEmpty) {
      await _state.setLastEntity(userId, name: nStr, type: 'payment');
    }
    _log('STEP', 'selection_pick index=${idx + 1}');
    return _beginPaymentDueSettlement(userId, c, row);
  }

  Future<ProcessResult> _handleQuotationFollowupPick(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final list = flow.selectionList;
    if (list.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly(
        'Quotation list khaali thi — dubara follow-up try karein.',
      );
    }
    final idx = _selectionIndexFromText(t, list.length);
    if (idx == null) {
      return ProcessResult.assistantOnly('1 se ${list.length} number bhejein.');
    }
    final row = list[idx];
    final quoteId = (row['quotationId'] as String? ?? '').trim();
    final name = (row['name'] as String? ?? '').trim();
    if (quoteId.isEmpty || name.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly(
        'Quotation selection invalid tha — dubara try karein.',
      );
    }
    final pd = Map<String, dynamic>.from(
      FlowStepEngine.initialPendingData('quotation', 'followup'),
    )
      ..['quotationId'] = quoteId
      ..['name'] = name
      ..['clientName'] = name;
    if (row['amount'] is num) {
      pd['amount'] = (row['amount'] as num).toDouble();
    }
    await _state.updateState(
      userId,
      ChatFlowState(
        currentCategory: 'quotation',
        currentSubcategory: 'followup',
        flowCategoryId: flowCategoryIdFor('quotation', 'followup'),
        pendingAction: ChatFlowState.actionCollecting,
        stepIndex: 1,
        pendingData: pd,
      ),
    );
    return ProcessResult.assistantOnly(
      FlowStepEngine.getNextQuestion(1, 'quotation', 'followup'),
    );
  }

  Future<ProcessResult> _handleOrderUpdateMode(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final low = t.trim().toLowerCase();
    String? mode;
    if (low == '1' || low.contains('process')) {
      mode = 'process';
    } else if (low == '2' || low.contains('dispatch')) {
      mode = 'dispatch';
    }
    if (mode == null) {
      return const ProcessResult.assistantOnly(
        '1 = Process, 2 = Dispatch. Number bhejein.',
      );
    }
    await _state.updateState(
      userId,
      ChatFlowState(
        currentCategory: flow.currentCategory ?? 'order',
        currentSubcategory: flow.currentSubcategory ?? 'update',
        flowCategoryId: flow.flowCategoryId ?? flowCategoryIdFor('order', 'update'),
        pendingAction: ChatFlowState.actionPendingSelection,
        stepIndex: 0,
        pendingSelection: true,
        selectionType: ChatFlowState.selectionOrderClientPick,
        selectionList: const [],
        pendingData: {'orderUpdateMode': mode},
      ),
    );
    return _openPendingOrderClientPicker(userId, mode, flow);
  }

  Future<ProcessResult> _handleOrderClientName(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final mode = (flow.pendingData['orderUpdateMode'] as String? ?? '').trim();
    if (mode != 'process' && mode != 'dispatch') {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('State error — order update dubara start karein.');
    }
    final client = capitalizeWords(t.trim());
    if (client.length < 2) {
      return const ProcessResult.assistantOnly('Client naam thoda clear likhiye.');
    }
    final rows = await _orders.fetchPendingOrdersForClient(userId, client);
    if (rows.isEmpty) {
      await _state.clearState(userId);
      return ProcessResult.assistantOnly('`$client` ke pending orders nahi mile.');
    }
    if (rows.length == 1) {
      return _routeSelectedOrderForUpdate(
        userId: userId,
        flow: flow,
        order: rows.first,
        mode: mode,
      );
    }
    final df = DateFormat('d MMM');
    final list = <Map<String, dynamic>>[];
    final out = StringBuffer('$client ke pending orders:\n\n');
    final cur = NumberFormat.currency(
      locale: 'en_IN',
      symbol: '₹',
      decimalDigits: 0,
    );
    for (var i = 0; i < rows.length; i++) {
      final o = rows[i];
      final dt = o.createdAtMs > 0
          ? df.format(DateTime.fromMillisecondsSinceEpoch(o.createdAtMs))
          : '—';
      out.writeln('${i + 1}. ${cur.format(o.amount)} ($dt)');
      list.add({
        'orderId': o.id,
        'clientName': o.clientName ?? client,
        'amount': o.amount,
        'createdAtMs': o.createdAtMs,
      });
    }
    out.writeln('\nNumber bhejein (1-${rows.length}).');
    await _state.updateState(
      userId,
      ChatFlowState(
        currentCategory: flow.currentCategory ?? 'order',
        currentSubcategory: flow.currentSubcategory ?? 'update',
        flowCategoryId: flow.flowCategoryId ?? flowCategoryIdFor('order', 'update'),
        pendingAction: ChatFlowState.actionPendingSelection,
        pendingSelection: true,
        selectionType: mode == 'process'
            ? ChatFlowState.selectionOrderProcessPick
            : ChatFlowState.selectionOrderDispatchPick,
        selectionList: list,
        pendingData: {'orderUpdateMode': mode},
      ),
    );
    return ProcessResult.assistantOnly(out.toString().trim());
  }

  Future<ProcessResult> _handleOrderPendingSelection(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    if (flow.selectionType == ChatFlowState.selectionOrderClientPick) {
      final idx = _selectionIndexFromText(t, flow.selectionList.length);
      if (idx == null) {
        return ProcessResult.assistantOnly(
          '1 se ${flow.selectionList.length} number bhejein.',
        );
      }
      final row = flow.selectionList[idx];
      final clientName = (row['clientName'] as String? ?? '').trim();
      if (clientName.isEmpty) {
        await _state.clearState(userId);
        return const ProcessResult.assistantOnly('Client row error — dubara try karein.');
      }
      final mode = (flow.pendingData['orderUpdateMode'] as String? ?? '').trim();
      final rows = await _orders.fetchPendingOrdersForClient(userId, clientName);
      if (rows.isEmpty) {
        await _state.clearState(userId);
        return ProcessResult.assistantOnly('`$clientName` ke pending orders nahi mile.');
      }
      if (rows.length == 1) {
        return _routeSelectedOrderForUpdate(
          userId: userId,
          flow: flow,
          order: rows.first,
          mode: mode,
        );
      }
      final df = DateFormat('d MMM');
      final list = <Map<String, dynamic>>[];
      final out = StringBuffer('$clientName ke pending orders:\n\n');
      final cur = NumberFormat.currency(
        locale: 'en_IN',
        symbol: '₹',
        decimalDigits: 0,
      );
      for (var i = 0; i < rows.length; i++) {
        final o = rows[i];
        final dt = o.createdAtMs > 0
            ? df.format(DateTime.fromMillisecondsSinceEpoch(o.createdAtMs))
            : '—';
        out.writeln('${i + 1}. ${cur.format(o.amount)} ($dt)');
        list.add({
          'orderId': o.id,
          'clientName': o.clientName ?? clientName,
          'amount': o.amount,
          'createdAtMs': o.createdAtMs,
        });
      }
      out.writeln('\nNumber bhejein (1-${rows.length}).');
      await _state.updateState(
        userId,
        ChatFlowState(
          currentCategory: flow.currentCategory ?? 'order',
          currentSubcategory: flow.currentSubcategory ?? 'update',
          flowCategoryId:
              flow.flowCategoryId ?? flowCategoryIdFor('order', 'update'),
          pendingAction: ChatFlowState.actionPendingSelection,
          pendingSelection: true,
          selectionType: mode == 'process'
              ? ChatFlowState.selectionOrderProcessPick
              : ChatFlowState.selectionOrderDispatchPick,
          selectionList: list,
          pendingData: {'orderUpdateMode': mode},
        ),
      );
      return ProcessResult.assistantOnly(out.toString().trim());
    }
    final list = flow.selectionList;
    if (list.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('List khaali — dubara try karein.');
    }
    final idx = _selectionIndexFromText(t, list.length);
    if (idx == null) {
      return ProcessResult.assistantOnly('1 se ${list.length} number bhejein.');
    }
    final row = list[idx];
    final orderId = (row['orderId'] as String? ?? '').trim();
    if (orderId.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('Order row error — dubara try karein.');
    }
    final order = OrderRecord(
      id: orderId,
      amount: (row['amount'] as num?)?.toDouble() ?? 0,
      createdAtMs: (row['createdAtMs'] as num?)?.toInt() ?? 0,
      status: 'pending',
      clientName: (row['clientName'] as String?)?.trim(),
    );
    final mode = flow.selectionType == ChatFlowState.selectionOrderProcessPick
        ? 'process'
        : 'dispatch';
    return _routeSelectedOrderForUpdate(
      userId: userId,
      flow: flow,
      order: order,
      mode: mode,
    );
  }

  Future<ProcessResult> _openPendingOrderClientPicker(
    String userId,
    String mode,
    ChatFlowState flow,
  ) async {
    final pending = await _orders.fetchPendingOrders(userId);
    if (pending.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('Koi pending order nahi mila.');
    }
    final grouped = <String, Map<String, dynamic>>{};
    for (final o in pending) {
      final name = (o.clientName ?? '').trim().isEmpty ? 'Client' : o.clientName!.trim();
      final key = normalizeName(name);
      final cur = grouped[key];
      if (cur == null) {
        grouped[key] = {
          'clientName': name,
          'pendingCount': 1,
        };
      } else {
        cur['pendingCount'] = ((cur['pendingCount'] as int?) ?? 0) + 1;
      }
    }
    final rows = grouped.values.toList(growable: false)
      ..sort(
        (a, b) => (a['clientName'] as String)
            .toLowerCase()
            .compareTo((b['clientName'] as String).toLowerCase()),
      );
    final out = StringBuffer(
      '${mode == 'process' ? 'Process' : 'Dispatch'} ke liye client select karein:\n\n',
    );
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      out.writeln('${i + 1}. ${r['clientName']} (${r['pendingCount']} pending)');
    }
    out.writeln('\nNumber bhejein (1-${rows.length}).');
    await _state.updateState(
      userId,
      ChatFlowState(
        currentCategory: flow.currentCategory ?? 'order',
        currentSubcategory: flow.currentSubcategory ?? 'update',
        flowCategoryId: flow.flowCategoryId ?? flowCategoryIdFor('order', 'update'),
        pendingAction: ChatFlowState.actionPendingSelection,
        pendingSelection: true,
        selectionType: ChatFlowState.selectionOrderClientPick,
        selectionList: rows,
        pendingData: {'orderUpdateMode': mode},
      ),
    );
    return ProcessResult.assistantOnly(out.toString().trim());
  }

  Future<ProcessResult> _routeSelectedOrderForUpdate({
    required String userId,
    required ChatFlowState flow,
    required OrderRecord order,
    required String mode,
  }) async {
    if (mode == 'process') {
      await _state.updateState(
        userId,
        ChatFlowState(
          currentCategory: flow.currentCategory ?? 'order',
          currentSubcategory: flow.currentSubcategory ?? 'update',
          flowCategoryId: flow.flowCategoryId ?? flowCategoryIdFor('order', 'update'),
          pendingAction: ChatFlowState.actionAwaitingOrderProcessStage,
          stepIndex: 0,
          pendingData: {
            'orderUpdateMode': 'process',
            'orderId': order.id,
            'orderClientName': order.clientName ?? '',
          },
        ),
      );
      return const ProcessResult.assistantOnly(
        'Process stage select karein:\n'
        '1. Plate received\n'
        '2. Printing done\n'
        '3. Punching done\n'
        '4. Material ready',
      );
    }
    await _state.updateState(
      userId,
      ChatFlowState(
        currentCategory: flow.currentCategory ?? 'order',
        currentSubcategory: flow.currentSubcategory ?? 'update',
        flowCategoryId: flow.flowCategoryId ?? flowCategoryIdFor('order', 'update'),
        pendingAction: ChatFlowState.actionAwaitingOrderDispatchAmount,
        stepIndex: 0,
        pendingData: {
          'orderUpdateMode': 'dispatch',
          'orderId': order.id,
          'orderClientName': order.clientName ?? '',
          'orderAmount': order.amount,
        },
      ),
    );
    final cur = NumberFormat.currency(
      locale: 'en_IN',
      symbol: '₹',
      decimalDigits: 0,
    );
    return ProcessResult.assistantOnly(
      'Dispatch amount bhejein (default ${cur.format(order.amount)}).',
    );
  }

  Future<ProcessResult> _handleOrderProcessStage(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final orderId = (flow.pendingData['orderId'] as String? ?? '').trim();
    if (orderId.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('State error — order update dubara start karein.');
    }
    final low = t.trim().toLowerCase();
    String? stage;
    String? label;
    if (low == '1' || low.contains('plate')) {
      stage = 'plate_received';
      label = 'Plate received';
    } else if (low == '2' || low.contains('printing')) {
      stage = 'printing_done';
      label = 'Printing done';
    } else if (low == '3' || low.contains('punch')) {
      stage = 'punching_done';
      label = 'Punching done';
    } else if (low == '4' || low.contains('material')) {
      stage = 'material_ready';
      label = 'Material ready';
    }
    if (stage == null) {
      return const ProcessResult.assistantOnly('1-4 me se stage choose karein.');
    }
    await _orders.updateOrderProcessStage(
      userId: userId,
      orderId: orderId,
      processStage: stage,
    );
    await _state.clearState(userId);
    return ProcessResult.assistantOnly(
      'Process updated ✓\nStage: $label',
    );
  }

  Future<ProcessResult> _handleOrderDispatchDueChoice(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final low = t.trim().toLowerCase();
    if (low == '2' || low == 'no' || low == 'nahi') {
      final dispatchAmount =
          (flow.pendingData['dispatchAmount'] as num?)?.toDouble() ??
          (flow.pendingData['orderAmount'] as num?)?.toDouble() ??
          0;
      await _state.updateState(
        userId,
        ChatFlowState(
          currentCategory: flow.currentCategory,
          currentSubcategory: flow.currentSubcategory,
          flowCategoryId: flow.flowCategoryId,
          pendingAction: ChatFlowState.actionAwaitingOrderDispatchReceivedAmount,
          stepIndex: 0,
          pendingData: flow.pendingData,
        ),
      );
      final cur = NumberFormat.currency(
        locale: 'en_IN',
        symbol: '₹',
        decimalDigits: 0,
      );
      return ProcessResult.assistantOnly(
        'Kitna payment received hua? '
        '(dispatch ${cur.format(dispatchAmount)}; zyada bhi ho sakta hai)',
      );
    }
    if (low == '1' || low == 'yes' || low == 'haan') {
      await _state.updateState(
        userId,
        ChatFlowState(
          currentCategory: flow.currentCategory,
          currentSubcategory: flow.currentSubcategory,
          flowCategoryId: flow.flowCategoryId,
          pendingAction: ChatFlowState.actionAwaitingOrderDispatchTermDays,
          stepIndex: 0,
          pendingData: {
            ...flow.pendingData,
            'orderDispatchTermMode': 'full_due',
          },
        ),
      );
      return const ProcessResult.assistantOnly(
        'Payment term days bhejein (30 / 40 / 60 ya custom number).',
      );
    }
    return const ProcessResult.assistantOnly('1 = Yes, 2 = No.');
  }

  Future<ProcessResult> _handleOrderDispatchAmount(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final parsed = extractInrAmountFromText(t.trim()) ??
        double.tryParse(t.trim().replaceAll(RegExp(r'[₹,\s]'), ''));
    if (parsed == null || parsed <= 0) {
      return const ProcessResult.assistantOnly(
        'Valid dispatch amount bhejein, jaise 100000.',
      );
    }
    await _state.updateState(
      userId,
      ChatFlowState(
        currentCategory: flow.currentCategory,
        currentSubcategory: flow.currentSubcategory,
        flowCategoryId: flow.flowCategoryId,
        pendingAction: ChatFlowState.actionAwaitingOrderDispatchDueChoice,
        stepIndex: 0,
        pendingData: {
          ...flow.pendingData,
          'dispatchAmount': parsed,
        },
      ),
    );
    return const ProcessResult.assistantOnly(
      'Payment due create karna hai?\n'
      '1. Yes\n'
      '2. No',
    );
  }

  Future<ProcessResult> _handleOrderDispatchReceivedAmount(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final received = extractInrAmountFromText(t.trim()) ??
        double.tryParse(t.trim().replaceAll(RegExp(r'[₹,\s]'), ''));
    if (received == null || received <= 0) {
      return const ProcessResult.assistantOnly(
        'Valid received amount bhejein, jaise 50000.',
      );
    }
    final dispatchAmount =
        (flow.pendingData['dispatchAmount'] as num?)?.toDouble() ??
        (flow.pendingData['orderAmount'] as num?)?.toDouble() ??
        0;
    if (dispatchAmount <= 0) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('State error — dispatch amount missing.');
    }
    final pending = dispatchAmount - received;
    if (pending <= 0) {
      return _persistOrderDispatch(
        userId,
        flow,
        withDue: false,
        receivedAmount: received,
      );
    }
    await _state.updateState(
      userId,
      ChatFlowState(
        currentCategory: flow.currentCategory,
        currentSubcategory: flow.currentSubcategory,
        flowCategoryId: flow.flowCategoryId,
        pendingAction: ChatFlowState.actionAwaitingOrderDispatchTermDays,
        stepIndex: 0,
        pendingData: {
          ...flow.pendingData,
          'receivedAmount': received,
          'pendingAfterReceipt': pending,
          'orderDispatchTermMode': 'pending_after_receipt',
        },
      ),
    );
    final cur = NumberFormat.currency(
      locale: 'en_IN',
      symbol: '₹',
      decimalDigits: 0,
    );
    return ProcessResult.assistantOnly(
      'Pending ${cur.format(pending)} bacha hai. '
      'Payment term days bhejein (30 / 40 / 60 ya custom number).',
    );
  }

  Future<ProcessResult> _handleOrderDispatchTermDays(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final raw = t.trim();
    final m = RegExp(r'\d+').firstMatch(raw);
    final days = m == null ? null : int.tryParse(m.group(0)!);
    if (days == null || days <= 0) {
      return const ProcessResult.assistantOnly('Valid days bhejein, jaise 30.');
    }
    final mode = (flow.pendingData['orderDispatchTermMode'] as String? ?? '').trim();
    if (mode == 'pending_after_receipt') {
      return _persistOrderDispatch(
        userId,
        flow,
        withDue: true,
        termDays: days,
        receivedAmount: (flow.pendingData['receivedAmount'] as num?)?.toDouble(),
      );
    }
    return _persistOrderDispatch(
      userId,
      flow,
      withDue: true,
      termDays: days,
    );
  }

  Future<ProcessResult> _persistOrderDispatch(
    String userId,
    ChatFlowState flow, {
    required bool withDue,
    int? termDays,
    double? receivedAmount,
  }) async {
    final orderId = (flow.pendingData['orderId'] as String? ?? '').trim();
    final clientName = (flow.pendingData['orderClientName'] as String? ?? '').trim();
    final orderAmount = (flow.pendingData['orderAmount'] as num?)?.toDouble() ?? 0;
    final dispatchAmount =
        (flow.pendingData['dispatchAmount'] as num?)?.toDouble() ??
        orderAmount;
    if (orderId.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('State error — order missing.');
    }
    int? dueMs;
    final resolvedClient = await _resolveOrCreateClientForOrderDispatch(
      userId,
      clientName,
    );
    if (receivedAmount != null && receivedAmount > 0) {
      await _payments.settlePaymentReceived(
        userId: userId,
        clientId: resolvedClient.id,
        clientName: resolvedClient.name,
        receivedAmount: receivedAmount,
        paymentNote: 'Order dispatch receipt',
      );
    }
    if (withDue) {
      final days = termDays ?? 0;
      if (days <= 0) {
        return const ProcessResult.assistantOnly('Payment term invalid.');
      }
      final now = DateTime.now();
      final dueDay = DateTime(
        now.year,
        now.month,
        now.day,
      ).add(Duration(days: days));
      dueMs = dueDay.millisecondsSinceEpoch;
      await _orders.markOrderDispatched(
        userId: userId,
        orderId: orderId,
        paymentTermDays: days,
        paymentDueDateMs: dueMs,
      );
      final pendingDueRaw =
          (flow.pendingData['pendingAfterReceipt'] as num?)?.toDouble() ??
          dispatchAmount;
      final pendingDue = pendingDueRaw < 0 ? 0.0 : pendingDueRaw;
      await _payments.createPaymentDue(
        userId: userId,
        clientId: resolvedClient.id,
        clientName: resolvedClient.name,
        amount: pendingDue,
        dueDateMs: dueMs,
        note: 'Order dispatch due ($days days term)',
      );
      await _payments.syncClientOutstandingForClient(userId, resolvedClient.id);
      final reminderAt = DateTime(
        dueDay.year,
        dueDay.month,
        dueDay.day,
        11,
        0,
      );
      final cur = NumberFormat.currency(
        locale: 'en_IN',
        symbol: '₹',
        decimalDigits: 0,
      );
      await _reminders.createReminder(
        userId: userId,
        title: 'Payment follow-up: ${resolvedClient.name}',
        scheduledAt: reminderAt,
        type: 'payment',
        subType: 'followup',
        note:
            '${cur.format(pendingDue)} due on ${DateFormat('d MMM').format(dueDay)}',
        clientName: resolvedClient.name,
      );
      await _state.clearState(userId);
      return ProcessResult.assistantOnly(
        'Dispatch marked ✓\n'
        'Payment due created ($days days)\n'
        'Reminder set: ${DateFormat('d MMM').format(dueDay)} 11:00 AM',
      );
    }
    await _orders.markOrderDispatched(userId: userId, orderId: orderId);
    await _state.clearState(userId);
    return const ProcessResult.assistantOnly(
      'Dispatch marked ✓\nPayment received entry saved.',
    );
  }

  Future<Client> _resolveOrCreateClientForOrderDispatch(
    String userId,
    String clientName,
  ) async {
    final safeName = clientName.trim().isEmpty ? 'Client' : clientName.trim();
    final res = await _clients.resolveForPaymentName(userId, safeName);
    if (res.client != null) {
      return res.client!;
    }
    if (res.candidates.isNotEmpty) {
      return res.candidates.first;
    }
    return _clients.createClient(userId, safeName);
  }

  Future<ProcessResult> _beginPaymentDueSettlement(
    String userId,
    Client c,
    Map<String, dynamic> row,
  ) async {
    final remRaw = row['remainingAmount'];
    final rowAmt = row['amount'];
    final dueRem = remRaw is num
        ? remRaw.toDouble()
        : (rowAmt is num ? rowAmt.toDouble() : null);
    if (dueRem == null || dueRem <= 0) {
      await _state.clearState(userId);
      _forgetSettlementPending(userId);
      return const ProcessResult.assistantOnly(
        'Ye due settle karne layak nahi — open amount check karein.',
      );
    }
    final name = (row['name'] as String? ?? c.name).trim();
    final source = row['source'] as String? ?? 'legacy_structured';
    final pid = row['id'] as String? ?? '';
    final inv = row['invoiceLabel'] as String?;
    final linked = source == 'firestore' ? pid : '';
    final structLeg = source == 'legacy_structured' ? pid : '';
    final cur = NumberFormat.currency(
      locale: 'en_IN',
      symbol: '₹',
      decimalDigits: 0,
    );
    final pending = <String, dynamic>{
      'settlementClientId': c.id,
      'settlementDisplayName': name.isNotEmpty ? name : c.name,
      'settlementLinkedPaymentId': linked,
      'settlementStructuredLegacyId': structLeg,
      'settlementDueRemaining': dueRem,
      if (inv != null && inv.isNotEmpty) 'settlementInvoiceLabel': inv,
    };
    await _state.updateState(
      userId,
      ChatFlowState(
        currentCategory: 'payment',
        currentSubcategory: 'received',
        flowCategoryId: flowCategoryIdFor('payment', 'received'),
        pendingAction: ChatFlowState.actionAwaitingPaymentSettlementAmount,
        stepIndex: 0,
        pendingData: pending,
      ),
    );
    _stashSettlementPending(userId, pending);
    if (name.isNotEmpty) {
      await _state.setLastEntity(userId, name: name, type: 'payment');
    }
    return ProcessResult.assistantOnly(
      'Pending amount: ${cur.format(dueRem)}\n\n'
      'Kitna payment receive hua?',
    );
  }

  Future<ProcessResult> _handlePaymentReceivedClientName(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final low = t.toLowerCase().trim();
    if (low == 'cancel' ||
        low == 'band' ||
        low.contains('chhod') ||
        low == 'quit') {
      await _state.clearState(userId);
      _forgetSettlementPending(userId);
      return const ProcessResult.assistantOnly('Theek — flow band.');
    }
    if (_looksLikeFollowupOrCallListQuestion(t)) {
      await _state.clearState(userId);
      _forgetSettlementPending(userId);
      return const ProcessResult.none();
    }
    final token = t.trim();
    if (token.length < 2) {
      return const ProcessResult.assistantOnly(
        'Client naam thoda clear likhiye (2+ characters).',
      );
    }
    final res = await _tryPaymentSelectionList(
      userId,
      normalizeName(token),
      rawNameToken: token,
      fromContextMemory: false,
    );
    if (res != null) {
      return res;
    }
    await _state.clearState(userId);
    return const ProcessResult.assistantOnly('Koi pending due nahi mila.');
  }

  Future<ProcessResult> _handlePaymentSettlementAmount(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final pd = _mergedSettlementPending(userId, flow.pendingData);
    final maxR =
        (pd['settlementDueRemaining'] as num?)?.toDouble();
    if (maxR == null || maxR <= 0) {
      await _state.clearState(userId);
      _forgetSettlementPending(userId);
      return const ProcessResult.assistantOnly('State error — dubara shuru karein.');
    }
    final a = extractInrAmountFromText(t.trim()) ??
        double.tryParse(t.trim().replaceAll(RegExp(r'[₹,\s]'), ''));
    if (a == null || a <= 0) {
      return const ProcessResult.assistantOnly(
        'Amount number mein likhiye — jaise 50000 ya ₹20,000.',
      );
    }
    if (a > maxR + 0.009) {
      final cur = NumberFormat.currency(
        locale: 'en_IN',
        symbol: '₹',
        decimalDigits: 0,
      );
      return ProcessResult.assistantOnly(
        'Ye pending ${cur.format(maxR)} se zyada nahi ho sakta — amount kam karke bataiye.',
      );
    }
    final nextData = Map<String, dynamic>.from(pd)
      ..['settlementReceivedAmount'] = a;
    _stashSettlementPending(userId, nextData);
    await _state.updateState(
      userId,
      ChatFlowState(
        currentCategory: flow.currentCategory,
        currentSubcategory: flow.currentSubcategory,
        flowCategoryId: flow.flowCategoryId,
        pendingAction: ChatFlowState.actionAwaitingPaymentSettlementDate,
        stepIndex: 0,
        pendingData: nextData,
      ),
    );
    return const ProcessResult.assistantOnly(
      '📅 Payment receive date? (aaj / kal / 5 May — khaali = **aaj**)',
    );
  }

  /// Controlled-flow step: persist received payment calendar day ([parseConversationalDate]).
  Future<ProcessResult> _handlePaymentReceivedDate(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    if (kDebugMode) {
      debugPrint(
        '[AIVY_ROUTE] handlePaymentReceivedDate raw="${t.trim()}" '
        'pa=${flow.pendingAction}',
      );
    }
    final pd = _mergedSettlementPending(userId, flow.pendingData);
    final received = (pd['settlementReceivedAmount'] as num?)?.toDouble();
    if (received == null || received <= 0) {
      await _state.clearState(userId);
      _forgetSettlementPending(userId);
      return const ProcessResult.assistantOnly('State error — dubara shuru karein.');
    }
    final name = (pd['settlementDisplayName'] as String? ?? '').trim();
    final clientId = (pd['settlementClientId'] as String? ?? '').trim();
    final linked = (pd['settlementLinkedPaymentId'] as String? ?? '').trim();
    final structLeg =
        (pd['settlementStructuredLegacyId'] as String? ?? '').trim();
    if (clientId.isEmpty || name.isEmpty) {
      await _state.clearState(userId);
      _forgetSettlementPending(userId);
      return const ProcessResult.assistantOnly('State error — dubara shuru karein.');
    }
    final trimmed = normalizeLatinHomoglyphsForDateInput(t).trim();
    final now = DateTime.now();
    final day = parseConversationalDate(trimmed, reference: now);
    if (day == null) {
      return ProcessResult.assistantOnly(
        conversationalDateParseExamplesMessage,
      );
    }
    final dayMs = day.millisecondsSinceEpoch;
    final map = <String, dynamic>{
      'flowCategoryId': 'payment_received',
      'type': 'payment',
      'subType': 'payment_received',
      'clientId': clientId,
      'name': name,
      'amount': received,
      'date': dayMs,
      'status': 'pending',
      if (linked.isNotEmpty) 'linkedPaymentId': linked,
      if (structLeg.isNotEmpty) 'structuredLegacyId': structLeg,
    };

    ConfirmPayloadMapper.debugUserInput(
      trimmed.isEmpty ? '(default today)' : trimmed,
    );
    ConfirmPayloadMapper.debugDraftBeforeSave(map);

    _forgetSettlementPending(userId);

    final draft = draftFromMap(map);
    final summary = formatConfirmSummary(map, draft);
    if (kDebugMode) {
      debugPrint(
        '[AIVY_TRACE_CONFIRM] _handlePaymentReceivedDate about to RETURN '
        'ProcessKind.inChatConfirm '
        'draft.type=${draft.type} draft.subType=${draft.subType} '
        'mapKeys=${map.keys.toList()} '
        'confirmDraftNull=false summaryChars=${summary.length} '
        'aivyQuick=${_quickRepliesAivy['quickReplies']}',
      );
    }
    return ProcessResult.inChatConfirm(
      draft,
      summary: summary,
      confirmDraftMap: map,
      aivyData: _quickRepliesAivy,
    );
  }

  Future<ProcessResult> _handleClientPick(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final list = flow.selectionList;
    if (list.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('List khaali — dubara try karein.');
    }
    final idx = _selectionIndexFromText(t, list.length);
    if (idx == null) {
      return ProcessResult.assistantOnly(
        '1 se ${list.length} number bhejein.',
      );
    }
    final row = list[idx];
    if (row['openDuesNamePick'] == true) {
      final nm = (row['name'] as String? ?? '').trim();
      if (nm.length < 2) {
        await _state.clearState(userId);
        return const ProcessResult.assistantOnly('Row error.');
      }
      final all = await _collectAllOpenDueRows(userId);
      final want = ClientRepository.normalizeForMatch(nm);
      final hit = all
          .where(
            (r) =>
                ClientRepository.normalizeForMatch(
                  (r['name'] as String? ?? '').trim(),
                ) ==
                want,
          )
          .toList();
      return _replyDuesReadOnlyForRowSubset(userId, hit);
    }
    final resumeRaw = flow.pendingData['clientPickResume'];
    final resumeMap = resumeRaw is Map<String, dynamic>
        ? resumeRaw
        : (resumeRaw is Map ? Map<String, dynamic>.from(resumeRaw) : null);
    final cid = row['id'] as String?;
    if ((cid == null || cid.isEmpty) &&
        resumeMap?['paymentFollowupClient'] == true) {
      final pickedName = (row['name'] as String? ?? '').trim();
      if (pickedName.length < 2) {
        await _state.clearState(userId);
        return const ProcessResult.assistantOnly('Row error.');
      }
      final resolved = await _clients.resolveForPaymentName(userId, pickedName);
      if (resolved.needsDisambiguation) {
        final buf = StringBuffer('Kaunsa client?\n\n');
        final disList = <Map<String, dynamic>>[];
        for (var i = 0; i < resolved.candidates.length; i++) {
          final cand = resolved.candidates[i];
          buf.writeln('${i + 1}. ${cand.name}');
          disList.add({'id': cand.id, 'name': cand.name});
        }
        await _state.updateState(
          userId,
          ChatFlowState(
            currentCategory: 'payment',
            currentSubcategory: 'followup',
            flowCategoryId: flowCategoryIdFor('payment', 'followup'),
            pendingAction: ChatFlowState.actionPendingSelection,
            selectionType: ChatFlowState.selectionClientPick,
            selectionList: disList,
            pendingSelection: true,
            pendingData: const {
              'clientPickResume': {'paymentFollowupClient': true},
            },
          ),
        );
        return ProcessResult.assistantOnly(buf.toString().trim());
      }
      final c = resolved.hasSingle
          ? resolved.client!
          : await _clients.createClient(userId, pickedName);
      await _state.updateState(
        userId,
        ChatFlowState(
          currentCategory: 'payment',
          currentSubcategory: 'followup',
          flowCategoryId: flowCategoryIdFor('payment', 'followup'),
          pendingAction: ChatFlowState.actionAwaitingFollowupAmount,
          pendingData: {'clientId': c.id, 'name': c.name},
        ),
      );
      return ProcessResult.assistantOnly(
        '${capitalizeWords(c.name)} selected.\n\n💰 Amount kitna hai? (₹)',
      );
    }
    if (cid == null || cid.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('Row error.');
    }
    final c = await _clients.getById(userId, cid);
    if (c == null) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('Client nahi mila.');
    }
    if (resumeMap != null) {
      final m = Map<String, dynamic>.from(resumeMap);
      if (m['viewOpenDuesOnly'] == true) {
        await _state.clearState(userId);
        return _replyClientOpenDuesReadOnly(userId, c);
      }
      if (m['paymentReceivedClientList'] == true) {
        await _state.clearState(userId);
        final next = await _openPendingPaymentsForClient(userId, c);
        if (next == null) {
          return const ProcessResult.assistantOnly(
            'Koi pending due nahi mila.',
          );
        }
        return next;
      }
      if (m['paymentFollowupClient'] == true) {
        await _state.updateState(
          userId,
          ChatFlowState(
            currentCategory: 'payment',
            currentSubcategory: 'followup',
            flowCategoryId: flowCategoryIdFor('payment', 'followup'),
            pendingAction: ChatFlowState.actionAwaitingFollowupAmount,
            pendingData: {'clientId': c.id, 'name': c.name},
          ),
        );
        return ProcessResult.assistantOnly(
          '${capitalizeWords(c.name)} selected.\n\n💰 Amount kitna hai? (₹)',
        );
      }
      if (m['directReceive'] == true) {
        final amt = (m['amount'] as num?)?.toDouble() ?? 0.0;
        final rows = await _mergedOpenDuesForClient(userId, c);
        double rowRem(Map<String, dynamic> r) {
          final x = r['remainingAmount'];
          if (x is num) {
            return x.toDouble();
          }
          return (r['amount'] as num?)?.toDouble() ?? 0.0;
        }

        if (rows.isEmpty) {
          await _state.clearState(userId);
          return const ProcessResult.assistantOnly('Koi pending due nahi mila.');
        }
        final linked = rows.where((r) => rowRem(r) == amt).toList();
        Map<String, dynamic>? pick;
        if (linked.length == 1) {
          pick = linked.single;
        } else if (rows.length == 1) {
          pick = rows.single;
        }
        if (pick != null) {
          return _beginPaymentDueSettlement(userId, c, pick);
        }
        final buf = StringBuffer();
        if (amt > 0) {
          buf.writeln(
            'Is amount (${NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0).format(amt)}) ki exact open due nahi mili — chunein:\n\n',
          );
        } else {
          buf.writeln('Kaunsi payment receive hui?\n\n');
        }
        final sl = <Map<String, dynamic>>[];
        for (var i = 0; i < rows.length; i++) {
          buf.writeln(_formatPaymentRowLine(i + 1, rows[i]));
          sl.add(rows[i]);
        }
        buf.writeln('\nNumber bhejein (1–${rows.length}).');
        await _state.updateState(
          userId,
          ChatFlowState(
            pendingAction: ChatFlowState.actionPendingSelection,
            selectionType: ChatFlowState.selectionPaymentUpdate,
            selectionList: sl,
            pendingSelection: true,
            stepIndex: 0,
            pendingData: const {},
          ),
        );
        return ProcessResult.assistantOnly(buf.toString().trim());
      }
      final stepRaw = m['stepData'];
      if (stepRaw is Map) {
        final fm = Map<String, dynamic>.from(stepRaw);
        fm['clientId'] = c.id;
        fm['name'] = c.name;
        await _state.clearState(userId);
        final cat = m['cat'] as String? ?? 'payment';
        final sub = m['sub'] as String? ?? 'due';
        final fcid0 =
            m['flowCategoryId'] as String? ?? flowCategoryIdFor(cat, sub);
        final draft = draftFromMap(fm);
        final fullMap =
            buildConfirmDraftMap(draft, flowCategoryId: fcid0, stepData: fm);
        return ProcessResult.inChatConfirm(
          draft,
          summary: formatConfirmSummary(fullMap, draft),
          confirmDraftMap: fullMap,
          aivyData: _quickRepliesAivy,
        );
      }
    }
    final fromCtx = flow.pendingData['fromContext'] == true;
    final next = await _openPendingPaymentsForClient(
      userId,
      c,
      fromContextMemory: fromCtx,
    );
    if (next == null) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly(
        'Koi pending due nahi mila.',
      );
    }
    if (next.kind == ProcessKind.inChatConfirm) {
      await _state.clearState(userId);
    }
    return next;
  }

  Future<List<Map<String, dynamic>>> _mergedOpenDuesForClient(
    String userId,
    Client c,
  ) async {
    final out = <Map<String, dynamic>>[];
    final ps = await _payments.getPendingPayments(userId, c.id);
    for (final p in ps) {
      out.add({
        'id': p.id,
        'source': 'firestore',
        'clientId': c.id,
        'name': p.clientName.isNotEmpty ? p.clientName : c.name,
        'amount': p.amount,
        'remainingAmount': p.effectiveRemaining,
        'status': p.status,
        'date': p.dueDateMs,
        'subType': p.subType,
        'invoiceLabel': p.invoiceLabel,
      });
    }
    final leg = await _structured.getAllOpenPaymentActions(userId);
    for (final a in leg) {
      final al = a.nameLower.isNotEmpty ? a.nameLower : normalizeName(a.name);
      if (al == c.nameLower) {
        out.add({
          'id': a.id,
          'source': 'legacy_structured',
          'clientId': c.id,
          'name': a.name.isNotEmpty ? a.name : c.name,
          'amount': a.amount,
          'remainingAmount': a.amount ?? 0.0,
          'status': a.status,
          'date': a.date?.millisecondsSinceEpoch,
          'subType': a.subType,
          'note': a.note,
        });
      }
    }
    out.sort(
      (a, b) => ((a['date'] as int?) ?? 0).compareTo((b['date'] as int?) ?? 0),
    );
    return out;
  }

  String _formatPaymentRowLine(
    int n,
    Map<String, dynamic> row, {
    bool showClientName = false,
  }) {
    final rem = row['remainingAmount'];
    final a = row['amount'];
    final display = rem is num ? rem : a;
    final cur = NumberFormat.currency(
      locale: 'en_IN',
      symbol: '₹',
      decimalDigits: 0,
    );
    final amt = display is num ? cur.format(display.toDouble()) : '—';
    var due = '—';
    final dm = row['date'];
    if (dm is int) {
      final d = DateTime.fromMillisecondsSinceEpoch(dm);
      due = DateFormat('d MMM').format(d);
    }
    final inv = (row['invoiceLabel'] as String? ?? '').trim();
    final invBit = inv.isNotEmpty ? ' — $inv' : '';
    final who = showClientName
        ? '${(row['name'] as String? ?? 'Client').trim()} — '
        : '';
    final stRaw = (row['status'] as String? ?? 'pending').toLowerCase();
    final stLabel = switch (stRaw) {
      'overdue' => 'Overdue',
      'partial_pending' => 'Partial pending',
      _ => 'Pending',
    };
    return '$n. $who$amt – Due $due ($stLabel)$invBit';
  }

  Future<ProcessResult?> _openPendingPaymentsForClient(
    String userId,
    Client c, {
    bool fromContextMemory = false,
  }) async {
    final rows = await _mergedOpenDuesForClient(userId, c);
    if (rows.isEmpty) {
      return null;
    }
    if (rows.length == 1) {
      return _beginPaymentDueSettlement(userId, c, rows.first);
    }
    final buf = StringBuffer();
    final proactive = await _proactiveOpenPaymentsLine(userId);
    if (proactive != null) {
      buf.writeln(proactive);
      buf.writeln();
    }
    buf.writeln('${c.name} ke pending dues:');
    buf.writeln();
    buf.writeln('Kaunsi payment receive hui?\n');
    final sl = <Map<String, dynamic>>[];
    for (var i = 0; i < rows.length; i++) {
      buf.writeln(_formatPaymentRowLine(i + 1, rows[i]));
      sl.add(rows[i]);
    }
    buf.writeln('\nNumber bhejein (1–${rows.length}).');
    await _state.updateState(
      userId,
      ChatFlowState(
        pendingAction: ChatFlowState.actionPendingSelection,
        selectionType: ChatFlowState.selectionPaymentUpdate,
        selectionList: sl,
        pendingSelection: true,
        stepIndex: 0,
        pendingData: {
          'clientId': c.id,
          'fromContext': fromContextMemory,
          'fuzzyQuery': normalizeName(c.name),
        },
      ),
    );
    return ProcessResult.assistantOnly(buf.toString().trim());
  }

  Future<ProcessResult?> _ensureClientForPaymentMap(
    String userId,
    Map<String, dynamic> fullMap,
    String cat,
    String sub,
    String fcidOut,
  ) async {
    final name =
        (fullMap['name'] as String? ?? fullMap['clientName'] as String? ?? '')
            .trim();
    if (name.isEmpty) {
      return null;
    }
    if ((fullMap['clientId'] as String? ?? '').trim().isNotEmpty) {
      return null;
    }
    final resolution = await _clients.resolveForPaymentName(userId, name);
    if (resolution.hasSingle) {
      final c = resolution.client!;
      fullMap['clientId'] = c.id;
      fullMap['name'] = c.name;
      return null;
    }
    if (resolution.needsDisambiguation) {
      final buf = StringBuffer('Kaunsa client?\n\n');
      final list = <Map<String, dynamic>>[];
      for (var i = 0; i < resolution.candidates.length; i++) {
        buf.writeln('${i + 1}. ${resolution.candidates[i].name}');
        list.add({
          'id': resolution.candidates[i].id,
          'name': resolution.candidates[i].name,
        });
      }
      await _state.updateState(
        userId,
        ChatFlowState(
          pendingAction: ChatFlowState.actionPendingSelection,
          selectionType: ChatFlowState.selectionClientPick,
          selectionList: list,
          pendingSelection: true,
          pendingData: {
            'clientPickResume': {
              'cat': cat,
              'sub': sub,
              'flowCategoryId': fcidOut,
              'stepData': Map<String, dynamic>.from(fullMap),
            },
          },
        ),
      );
      return ProcessResult.assistantOnly(buf.toString().trim());
    }

    await _state.updateState(
      userId,
      ChatFlowState(
        pendingAction: ChatFlowState.actionAwaitingCreateClientConfirm,
        pendingData: {
          'resume': {
            'fullMap': Map<String, dynamic>.from(fullMap),
            'cat': cat,
            'sub': sub,
            'flowCategoryId': fcidOut,
          },
        },
      ),
    );
    return ProcessResult.assistantOnly(
      'Client nahi mila. Naya create karu? (Yes/No)',
      aivyData: _createClientConfirmReplies,
    );
  }

  Future<ProcessResult> _handleAwaitingCreateClientConfirm(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final low = t.toLowerCase().trim();
    final resume = flow.pendingData['resume'];
    if (resume is! Map) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('State lost.');
    }
    final no = low == 'no' ||
        low == 'nahi' ||
        low == '2' ||
        low == 'na' ||
        low.startsWith('no ');
    final yes = low == 'yes' ||
        low == 'haan' ||
        low == 'y' ||
        low == '1' ||
        low == 'ha' ||
        low.startsWith('yes ');
    if (no) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly(
        'Theek — naya client nahi banaya. Jab chaho flow dubara chalu karein.',
      );
    }
    if (!yes) {
      return ProcessResult.assistantOnly(
        'Client nahi mila. Naya create karu?\n\nReply: Yes ya No.',
        aivyData: _createClientConfirmReplies,
      );
    }
    await _state.updateState(
      userId,
      ChatFlowState(
        pendingAction: ChatFlowState.actionAwaitingNewClientName,
        pendingData: {'resume': Map<String, dynamic>.from(resume)},
      ),
    );
    return const ProcessResult.assistantOnly(
      'Naya client ka poora naam likhein.\nExample: naya Rakesh Sharma',
    );
  }

  Future<ProcessResult> _handleAwaitingNewClientName(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final r = flow.pendingData['resume'];
    if (r is! Map) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('State lost.');
    }
    final rm = Map<String, dynamic>.from(r);
    final fullRaw = rm['fullMap'];
    if (fullRaw is! Map) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('Draft lost.');
    }
    var newName = t.trim();
    final naya = RegExp(
      r'^naya\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(newName);
    if (naya != null) {
      newName = (naya.group(1) ?? '').trim();
    }
    if (newName.length < 2) {
      return const ProcessResult.assistantOnly(
        'Poora naam likhiye — jaise: naya Rakesh Sharma',
      );
    }
    if (ClientRepository.looksLikeChatNoiseClientName(newName)) {
      return const ProcessResult.assistantOnly(
        'Ye naam client ke liye sahi nahi lag raha — poora business/client naam likhiye.',
      );
    }
    final c = await _clients.createClient(userId, newName);
    final fm = Map<String, dynamic>.from(fullRaw);
    fm['clientId'] = c.id;
    fm['name'] = c.name;
    final cat = rm['cat'] as String? ?? 'payment';
    final sub = rm['sub'] as String? ?? 'due';
    final fcid0 =
        rm['flowCategoryId'] as String? ?? flowCategoryIdFor(cat, sub);
    await _state.clearState(userId);
    final draft = draftFromMap(fm);
    final fullMap =
        buildConfirmDraftMap(draft, flowCategoryId: fcid0, stepData: fm);
    return ProcessResult.inChatConfirm(
      draft,
      summary: formatConfirmSummary(fullMap, draft),
      confirmDraftMap: fullMap,
      aivyData: _quickRepliesAivy,
    );
  }

  Future<List<Map<String, dynamic>>> _collectAllOpenDueRows(
    String userId,
  ) async {
    final all = await _payments.getAllOpenDues(userId);
    final leg = await _structured.getAllOpenPaymentActions(userId);
    final rows = <Map<String, dynamic>>[];
    for (final p in all) {
      rows.add({
        'id': p.id,
        'source': 'firestore',
        'clientId': p.clientId,
        'name': p.clientName,
        'amount': p.amount,
        'remainingAmount': p.effectiveRemaining,
        'status': p.status,
        'date': p.dueDateMs,
        'subType': p.subType,
        'invoiceLabel': p.invoiceLabel,
      });
    }
    for (final a in leg) {
      final match = rows.any(
        (e) => e['id'] == a.id && e['source'] == 'legacy_structured',
      );
      if (match) {
        continue;
      }
      rows.add({
        'id': a.id,
        'source': 'legacy_structured',
        'clientId': '',
        'name': a.name,
        'amount': a.amount,
        'remainingAmount': a.amount ?? 0.0,
        'status': a.status,
        'date': a.date?.millisecondsSinceEpoch,
        'subType': a.subType,
      });
    }
    rows.sort(
      (a, b) =>
          ((a['date'] as int?) ?? 0).compareTo((b['date'] as int?) ?? 0),
    );
    return rows;
  }

  String _formatReadOnlyDuesBlock(
    String title,
    List<Map<String, dynamic>> rows, {
    required bool showClientOnEachRow,
    String? subtitle,
  }) {
    final buf = StringBuffer();
    buf.writeln(title);
    if (subtitle != null && subtitle.trim().isNotEmpty) {
      buf.writeln('\n${subtitle.trim()}\n');
    } else {
      buf.writeln();
    }
    for (var i = 0; i < rows.length; i++) {
      buf.writeln(
        _formatPaymentRowLine(
          i + 1,
          rows[i],
          showClientName: showClientOnEachRow,
        ),
      );
    }
    buf.writeln(
      '\n— Naya due / follow-up: Payment → Follow-up → Payment follow-up.',
    );
    return buf.toString().trim();
  }

  Future<ProcessResult> _replyAllOpenDuesReadOnly(String userId) async {
    final rows = await _collectAllOpenDueRows(userId);
    await _state.clearState(userId);
    if (rows.isEmpty) {
      return const ProcessResult.assistantOnly('Koi open pending payment nahi.');
    }
    return ProcessResult.assistantOnly(
      _formatReadOnlyDuesBlock(
        '📋 Saari pending dues (vasoolni baaki):',
        rows,
        showClientOnEachRow: true,
      ),
    );
  }

  Future<ProcessResult> _replyClientOpenDuesReadOnly(
    String userId,
    Client c,
  ) async {
    final rows = await _mergedOpenDuesForClient(userId, c);
    await _state.clearState(userId);
    if (rows.isEmpty) {
      return ProcessResult.assistantOnly(
        '${c.name}: abhi koi open pending payment due nahi mila.',
      );
    }
    return ProcessResult.assistantOnly(
      _formatReadOnlyDuesBlock(
        '📋 Pending dues:',
        rows,
        showClientOnEachRow: false,
        subtitle: c.name,
      ),
    );
  }

  Future<ProcessResult> _replyDuesReadOnlyForRowSubset(
    String userId,
    List<Map<String, dynamic>> rows,
  ) async {
    await _state.clearState(userId);
    if (rows.isEmpty) {
      return const ProcessResult.assistantOnly('Koi pending due nahi mila.');
    }
    final subtitle = (rows.first['name'] as String? ?? '').trim();
    return ProcessResult.assistantOnly(
      _formatReadOnlyDuesBlock(
        '📋 Pending dues:',
        rows,
        showClientOnEachRow: false,
        subtitle: subtitle.isNotEmpty ? subtitle : null,
      ),
    );
  }

  /// When [clients] collection has no row but open dues use this name (e.g. "Karan").
  Future<ProcessResult?> _tryReplyDuesMatchingPaymentNames(
    String userId,
    String rawQuery,
  ) async {
    final qn = ClientRepository.normalizeForMatch(rawQuery);
    if (qn.length < 2) {
      return null;
    }
    final all = await _collectAllOpenDueRows(userId);
    bool rowMatches(Map<String, dynamic> row) {
      final nm = ClientRepository.normalizeForMatch(
        (row['name'] as String? ?? '').trim(),
      );
      if (nm.isEmpty) {
        return false;
      }
      if (nm == qn) {
        return true;
      }
      if (nm.startsWith(qn)) {
        return true;
      }
      if (qn.length >= 3 && nm.contains(qn)) {
        return true;
      }
      return false;
    }

    final matched = all.where(rowMatches).toList();
    if (matched.isEmpty) {
      return null;
    }

    final byKey = <String, List<Map<String, dynamic>>>{};
    for (final r in matched) {
      final cid = (r['clientId'] as String? ?? '').trim();
      final nm = ClientRepository.normalizeForMatch(
        (r['name'] as String? ?? '').trim(),
      );
      final key = cid.isNotEmpty ? 'id:$cid' : 'name:$nm';
      byKey.putIfAbsent(key, () => []).add(r);
    }

    if (byKey.length > 1) {
      final pickList = <Map<String, dynamic>>[];
      final buf = StringBuffer('Kaunsa client?\n\n');
      var i = 0;
      for (final e in byKey.entries) {
        final r0 = e.value.first;
        final cid = (r0['clientId'] as String? ?? '').trim();
        final disp = (r0['name'] as String? ?? '').trim().isNotEmpty
            ? (r0['name'] as String).trim()
            : 'Client';
        i++;
        buf.writeln('$i. $disp');
        if (cid.isNotEmpty) {
          pickList.add({'id': cid, 'name': disp});
        } else {
          pickList.add({
            'id': '',
            'name': disp,
            'openDuesNamePick': true,
          });
        }
      }
      await _state.updateState(
        userId,
        ChatFlowState(
          pendingAction: ChatFlowState.actionPendingSelection,
          selectionType: ChatFlowState.selectionClientPick,
          selectionList: pickList,
          pendingSelection: true,
          pendingData: const {
            'clientPickResume': {'viewOpenDuesOnly': true},
          },
        ),
      );
      return ProcessResult.assistantOnly(buf.toString().trim());
    }

    final sole = matched;
    final first = sole.first;
    final cid = (first['clientId'] as String? ?? '').trim();
    if (cid.isNotEmpty) {
      final c = await _clients.getById(userId, cid);
      if (c != null) {
        return _replyClientOpenDuesReadOnly(userId, c);
      }
      final disp = (first['name'] as String? ?? '').trim().isNotEmpty
          ? (first['name'] as String).trim()
          : 'Client';
      final syn = Client(
        id: cid,
        name: disp,
        nameLower: normalizeName(disp),
      );
      return _replyClientOpenDuesReadOnly(userId, syn);
    }
    return _replyDuesReadOnlyForRowSubset(userId, sole);
  }

  Future<ProcessResult> _handlePaymentDueChoice(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    if (_looksLikeFollowupOrCallListQuestion(t)) {
      await _state.clearState(userId);
      _forgetSettlementPending(userId);
      return const ProcessResult.none();
    }
    final low = t.toLowerCase().trim();
    if (_matchesFullPendingListUserReply(low)) {
      return _replyAllOpenDuesReadOnly(userId);
    }
    if (low == '2' ||
        low.contains('specific') ||
        low.contains('ek client') ||
        (low.contains('client') &&
            !low.contains('naya') &&
            !low.contains('add'))) {
      await _state.updateState(
        userId,
        ChatFlowState(
          currentCategory: flow.currentCategory ?? 'payment',
          currentSubcategory: flow.currentSubcategory ?? 'due',
          flowCategoryId:
              flow.flowCategoryId ?? flowCategoryIdFor('payment', 'due'),
          pendingAction: ChatFlowState.actionAwaitingPaymentDueClientName,
          stepIndex: 0,
          pendingData: const {},
        ),
      );
      return const ProcessResult.assistantOnly(
        'Kaunse client ki pending list chahiye? Naam likhiye.',
      );
    }

    final res = await _clients.resolveForPaymentName(userId, t);
    if (res.hasSingle) {
      return _replyClientOpenDuesReadOnly(userId, res.client!);
    }
    if (res.needsDisambiguation) {
      final buf = StringBuffer('Kaunsa client?\n\n');
      final list = <Map<String, dynamic>>[];
      for (var i = 0; i < res.candidates.length; i++) {
        buf.writeln('${i + 1}. ${res.candidates[i].name}');
        list.add({
          'id': res.candidates[i].id,
          'name': res.candidates[i].name,
        });
      }
      await _state.updateState(
        userId,
        ChatFlowState(
          pendingAction: ChatFlowState.actionPendingSelection,
          selectionType: ChatFlowState.selectionClientPick,
          selectionList: list,
          pendingSelection: true,
          pendingData: const {
            'clientPickResume': {'viewOpenDuesOnly': true},
          },
        ),
      );
      return ProcessResult.assistantOnly(buf.toString().trim());
    }

    final fromPay = await _tryReplyDuesMatchingPaymentNames(userId, t);
    if (fromPay != null) {
      return fromPay;
    }

    return const ProcessResult.assistantOnly(
      'Samjha nahi.\n\n'
      '1 — Saari pending list\n'
      '2 — Ek client (phir naam poochhunga)\n'
      'Ya seedha client ka naam likh dijiye.\n\n'
      'Naya due ke liye: Payment → Follow-up → Payment follow-up.',
    );
  }

  Future<ProcessResult> _handlePaymentDueClientName(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    if (t.trim().isEmpty) {
      return const ProcessResult.assistantOnly('Client ka naam likhiye.');
    }
    final low = t.toLowerCase().trim();

    if (isCategoryTrigger(t)) {
      await _state.clearState(userId);
      return ProcessResult.categoryFlow(getGreeting());
    }
    if (_isPaymentDueNameFlowCancel(low)) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly(
        'Theek — payment due flow band. Jo puchhna ho type karein.',
      );
    }
    if (_shouldDeferPaymentDueNameToCloud(t)) {
      _logCloudFallbackBlockCheck('defer_payment_due_name_cloudRun', flow);
      await _state.clearState(userId);
      return ProcessResult.cloudRun(t, intent: 'query');
    }
    if (_matchesFullPendingListUserReply(low)) {
      return _replyAllOpenDuesReadOnly(userId);
    }

    final res = await _clients.resolveForPaymentName(userId, t);
    if (res.hasSingle) {
      return _replyClientOpenDuesReadOnly(userId, res.client!);
    }
    if (res.needsDisambiguation) {
      final buf = StringBuffer('Kaunsa client?\n\n');
      final list = <Map<String, dynamic>>[];
      for (var i = 0; i < res.candidates.length; i++) {
        buf.writeln('${i + 1}. ${res.candidates[i].name}');
        list.add({
          'id': res.candidates[i].id,
          'name': res.candidates[i].name,
        });
      }
      await _state.updateState(
        userId,
        ChatFlowState(
          currentCategory: flow.currentCategory,
          currentSubcategory: flow.currentSubcategory,
          flowCategoryId: flow.flowCategoryId,
          pendingAction: ChatFlowState.actionPendingSelection,
          selectionType: ChatFlowState.selectionClientPick,
          selectionList: list,
          pendingSelection: true,
          pendingData: const {
            'clientPickResume': {'viewOpenDuesOnly': true},
          },
        ),
      );
      return ProcessResult.assistantOnly(buf.toString().trim());
    }

    final fromPay = await _tryReplyDuesMatchingPaymentNames(userId, t);
    if (fromPay != null) {
      return fromPay;
    }

    return const ProcessResult.assistantOnly(
      'Client match nahi hua — spelling check karein.\n'
      'Flow band karne ke liye **cancel** ya **band** likhiye, ya **+** se menu — phir dubara try karein.',
    );
  }

  // =====================================================================
  //  Payment Follow-up flow: create new payment_due + reminder at 11 AM
  // =====================================================================

  Future<ProcessResult> _handlePaymentFollowupChoice(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final low = t.toLowerCase().trim();
    if (low == '1' || low.contains('list') || low.contains('existing')) {
      final allClients = await _clients.listForPicker(userId);
      final merged = <String, Map<String, dynamic>>{};
      for (final c in allClients) {
        final norm = normalizeName(c.name);
        if (norm.isEmpty) {
          continue;
        }
        merged[norm] = {'id': c.id, 'name': c.name};
      }
      final dueRows = await _collectAllOpenDueRows(userId);
      for (final r in dueRows) {
        final nm = (r['name'] as String? ?? '').trim();
        if (nm.length < 2 ||
            ClientRepository.looksLikeChatNoiseClientName(nm)) {
          continue;
        }
        final norm = normalizeName(nm);
        if (norm.isEmpty || merged.containsKey(norm)) {
          continue;
        }
        final rowCid = (r['clientId'] as String? ?? '').trim();
        merged[norm] = {'id': rowCid, 'name': nm};
      }
      final list = merged.values.toList()
        ..sort(
          (a, b) => (a['name'] as String)
              .toLowerCase()
              .compareTo((b['name'] as String).toLowerCase()),
        );
      if (list.isEmpty) {
        await _state.updateState(
          userId,
          ChatFlowState(
            currentCategory: 'payment',
            currentSubcategory: 'followup',
            flowCategoryId: flowCategoryIdFor('payment', 'followup'),
            pendingAction: ChatFlowState.actionAwaitingFollowupNewClientName,
            pendingData: const {},
          ),
        );
        return const ProcessResult.assistantOnly(
          'Koi client nahi mila. Naye client ka naam likhiye.',
        );
      }
      final buf = StringBuffer('Client chunein:\n\n');
      for (var i = 0; i < list.length; i++) {
        buf.writeln('${i + 1}. ${list[i]['name']}');
      }
      buf.writeln('\nNumber bhejein.');
      await _state.updateState(
        userId,
        ChatFlowState(
          currentCategory: 'payment',
          currentSubcategory: 'followup',
          flowCategoryId: flowCategoryIdFor('payment', 'followup'),
          pendingAction: ChatFlowState.actionPendingSelection,
          selectionType: ChatFlowState.selectionClientPick,
          selectionList: list,
          pendingSelection: true,
          pendingData: const {
            'clientPickResume': {'paymentFollowupClient': true},
          },
        ),
      );
      return ProcessResult.assistantOnly(buf.toString().trim());
    }
    if (low == '2' || low.contains('naya') || low.contains('new') || low.contains('add')) {
      await _state.updateState(
        userId,
        ChatFlowState(
          currentCategory: 'payment',
          currentSubcategory: 'followup',
          flowCategoryId: flowCategoryIdFor('payment', 'followup'),
          pendingAction: ChatFlowState.actionAwaitingFollowupNewClientName,
          pendingData: const {},
        ),
      );
      return const ProcessResult.assistantOnly(
        'Naye client ka naam likhiye.',
      );
    }
    return const ProcessResult.assistantOnly(
      'Number bhejein:\n1. Client list se chunein\n2. Naya client add karein',
    );
  }

  Future<ProcessResult> _handleFollowupNewClientName(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    var newName = t.trim();
    final naya = RegExp(r'^naya\s+(.+)$', caseSensitive: false).firstMatch(newName);
    if (naya != null) newName = (naya.group(1) ?? '').trim();
    if (newName.length < 2) {
      return const ProcessResult.assistantOnly(
        'Poora naam likhiye — jaise Rakesh Sharma',
      );
    }
    if (ClientRepository.looksLikeChatNoiseClientName(newName)) {
      return const ProcessResult.assistantOnly(
        'Ye naam client ke liye sahi nahi lag raha — poora business/client naam likhiye.',
      );
    }
    final c = await _clients.createClient(userId, newName);
    await _state.updateState(
      userId,
      ChatFlowState(
        currentCategory: 'payment',
        currentSubcategory: 'followup',
        flowCategoryId: flowCategoryIdFor('payment', 'followup'),
        pendingAction: ChatFlowState.actionAwaitingFollowupAmount,
        pendingData: {'clientId': c.id, 'name': c.name},
      ),
    );
    return ProcessResult.assistantOnly(
      '✅ Client "${capitalizeWords(c.name)}" add ho gaya.\n\n💰 Amount kitna hai? (₹)',
    );
  }

  Future<ProcessResult> _handleFollowupAmount(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final amt = extractInrAmountFromText(t) ??
        double.tryParse(t.trim().replaceAll(RegExp(r'[₹,\s]'), ''));
    if (amt == null || amt <= 0) {
      return const ProcessResult.assistantOnly(
        'Amount sahi se likhiye — jaise 50000 ya ₹1,20,000.',
      );
    }
    final data = Map<String, dynamic>.from(flow.pendingData)..['amount'] = amt;
    await _state.updateState(
      userId,
      ChatFlowState(
        currentCategory: 'payment',
        currentSubcategory: 'followup',
        flowCategoryId: flowCategoryIdFor('payment', 'followup'),
        pendingAction: ChatFlowState.actionAwaitingFollowupDate,
        pendingData: data,
      ),
    );
    return const ProcessResult.assistantOnly(
      '📅 Due date kab hai?\n'
      '(jaise: 15 din baad, 10 din ke baad, kal, 25/05/2026)',
    );
  }

  Future<ProcessResult> _handleFollowupDate(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final day = ReminderTimeParser.resolveDateDayForReminderFlow(t.trim());
    if (day == null) {
      return const ProcessResult.assistantOnly(
        'Date samajh nahi aayi — jaise likhiye:\n'
        '• 15 din baad\n'
        '• kal\n'
        '• 25/05/2026',
      );
    }
    final data = Map<String, dynamic>.from(flow.pendingData);
    final dueDateMs = day.millisecondsSinceEpoch;
    data['date'] = dueDateMs;

    final clientId = (data['clientId'] as String? ?? '').trim();
    final name = (data['name'] as String? ?? '').trim();
    final amount = (data['amount'] as num?)?.toDouble() ?? 0.0;

    final nameCap = capitalizeWords(name);
    final cur = NumberFormat.currency(
      locale: 'en_IN', symbol: '₹', decimalDigits: 0);
    final dueLabel = DateFormat('d MMM yyyy').format(day);

    final map = <String, dynamic>{
      'flowCategoryId': 'payment_followup',
      'type': 'payment',
      'subType': 'payment_followup',
      'clientId': clientId,
      'name': nameCap,
      'amount': amount,
      'date': dueDateMs,
      'status': 'pending',
    };

    await _state.clearState(userId);
    _log('INTENT', 'draft_ready');
    _log('FINAL_DATA', map);
    final draft = draftFromMap(map);
    final fullMap = buildConfirmDraftMap(
      draft,
      flowCategoryId: 'payment_followup',
      stepData: map,
    );
    return ProcessResult.inChatConfirm(
      draft,
      summary:
          'Payment follow-up\n\n'
          'Client: $nameCap\n'
          'Amount: ${cur.format(amount)}\n'
          'Due: $dueLabel\n'
          'Reminder: $dueLabel 11:00 AM\n\n'
          '(Confirm / Edit / Cancel bhejein)',
      confirmDraftMap: fullMap,
      aivyData: _quickRepliesAivy,
    );
  }

  Future<ProcessResult> _handlePaymentReceivedChoice(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    if (_looksLikeFollowupOrCallListQuestion(t)) {
      await _state.clearState(userId);
      _forgetSettlementPending(userId);
      return const ProcessResult.none();
    }
    final low = t.toLowerCase().trim();
    if (low == '1' ||
        low.contains('naam') ||
        low.contains('name')) {
      await _state.updateState(
        userId,
        ChatFlowState(
          currentCategory: 'payment',
          currentSubcategory: 'received',
          flowCategoryId: flowCategoryIdFor('payment', 'received'),
          pendingAction: ChatFlowState.actionAwaitingPaymentReceivedClientName,
          stepIndex: 0,
          pendingData: const {},
        ),
      );
      return const ProcessResult.assistantOnly(
        'Theek — **client ka naam** likhiye. System sirf **open pending dues** dhoondhega.\n'
        'Example: Karan',
      );
    }
    if (low == '2' ||
        low.contains('pending') ||
        low.contains('list')) {
      await _state.clearState(userId);
      final groups = await _payments.getPendingDuesGroupedByClient(userId);
      if (groups.isEmpty) {
        return const ProcessResult.assistantOnly('Koi pending due nahi mila.');
      }
      final cur = NumberFormat.currency(
        locale: 'en_IN',
        symbol: '₹',
        decimalDigits: 0,
      );
      final buf = StringBuffer(
        'Pending Clients:\n\n',
      );
      final sl = <Map<String, dynamic>>[];
      for (var i = 0; i < groups.length; i++) {
        final g = groups[i];
        buf.writeln('${i + 1}. ${g.clientName} — ${cur.format(g.totalPending)}');
        sl.add({
          'id': g.clientId,
          'name': g.clientName,
        });
      }
      buf.writeln('\nNumber bhejein (1–${groups.length}).');
      await _state.updateState(
        userId,
        ChatFlowState(
          pendingAction: ChatFlowState.actionPendingSelection,
          selectionType: ChatFlowState.selectionClientPick,
          selectionList: sl,
          pendingSelection: true,
          stepIndex: 0,
          pendingData: const {
            'clientPickResume': {'paymentReceivedClientList': true},
          },
        ),
      );
      return ProcessResult.assistantOnly(buf.toString().trim());
    }
    return const ProcessResult.assistantOnly(
      'Reply:\n1. Client ka naam\n2. Pending clients ki list',
    );
  }

  Future<void> _maybeAppendShortAliasForUser(
    String userId, {
    required String nameLower,
    required String shortQuery,
  }) async {
    final s = shortQuery.trim();
    if (s.isEmpty) {
      return;
    }
    final n = normalizeName(s);
    if (n.isEmpty || n == nameLower) {
      return;
    }
    await _structured.appendAliasIfMissing(
      userId,
      nameLower,
      aliasToken: n,
    );
  }

  Future<ProcessResult> _handleEditing(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final mode = flow.pendingData['editingMode'] as String? ?? 'pick';
    final dm = flow.pendingData['editingDraft'];
    if (dm is! Map) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('Edit state lost.');
    }
    final dmap = Map<String, dynamic>.from(dm);
    if (mode == 'pick') {
      final quick = tryParseInlineEdit(t, dmap);
      if (quick != null) {
        _log('INLINE_EDIT', quick);
        final merged = Map<String, dynamic>.from(dmap)..addAll(quick);
        final d = draftFromMap(merged);
        final sum = formatConfirmSummary(merged, d);
        await _state.updateState(
          userId,
          ChatFlowState(
            pendingAction: ChatFlowState.actionAwaitingChatConfirm,
            stepIndex: 0,
            pendingData: {'confirmDraft': merged},
          ),
        );
        return ProcessResult.inChatConfirm(
          d,
          summary: sum,
          confirmDraftMap: merged,
          aivyData: _quickRepliesAivy,
        );
      }
      final pick = t.trim();
      final fcidPick = (dmap['flowCategoryId'] as String? ?? '').trim();
      final rSubPick = _reminderSubFromFlowCategoryId(fcidPick);

      String? field;
      if (fcidPick == 'reminder_task') {
        if (pick == '1' || pick.toLowerCase() == 'task') {
          field = 'taskTitle';
        } else if (pick == '2' ||
            pick.toLowerCase() == 'deadline' ||
            pick.toLowerCase() == 'date') {
          field = 'date';
        } else if (pick == '3' || pick.toLowerCase() == 'priority') {
          field = 'priority';
        } else if (pick == '4' || pick.toLowerCase() == 'note') {
          field = 'note';
        } else if (pick == '5' || pick.toLowerCase() == 'client') {
          field = 'clientName';
        }
        if (field == null) {
          return const ProcessResult.assistantOnly(
            '1–5 mein se bataiye (Task, Deadline, Priority, Note, Client).',
          );
        }
      } else {
        if (pick == '1' || pick.toLowerCase() == 'name') {
          field = 'name';
        } else if (fcidPick == 'quotation_followup' ||
            fcidPick == 'followup_client') {
          if (pick == '2' || pick.toLowerCase() == 'date') {
            field = 'date';
          } else if (pick == '3' || pick.toLowerCase() == 'note') {
            field = 'note';
          }
        } else if (fcidPick == 'personal_task') {
          if (pick == '1' || pick.toLowerCase() == 'task') {
            field = 'name';
          } else if (pick == '2' || pick.toLowerCase() == 'date') {
            field = 'date';
          } else if (pick == '3' || pick.toLowerCase() == 'note') {
            field = 'note';
          }
        } else if (fcidPick == 'personal_birthday') {
          if (pick == '1' || pick.toLowerCase() == 'name') {
            field = 'name';
          } else if (pick == '2' || pick.toLowerCase() == 'birthday date') {
            field = 'birthDate';
          } else if (pick == '2' || pick.toLowerCase() == 'date') {
            field = 'birthDate';
          } else if (pick == '3' || pick.toLowerCase() == 'note') {
            field = 'note';
          }
        } else if (pick == '2' || pick.toLowerCase() == 'amount') {
          field = 'amount';
        } else if (pick == '3' || pick.toLowerCase() == 'date') {
          field = 'date';
        } else if (pick == '4' || pick.toLowerCase() == 'note') {
          field = 'note';
        }
        if (field == null) {
          if (fcidPick == 'quotation_followup' || fcidPick == 'followup_client') {
            return const ProcessResult.assistantOnly(
              '1–3 mein se bataiye (Name, Date, Note).',
            );
          }
          if (fcidPick == 'personal_task') {
            return const ProcessResult.assistantOnly(
              '1–3 mein se bataiye (Task, Date, Note).',
            );
          }
          if (fcidPick == 'personal_birthday') {
            return const ProcessResult.assistantOnly(
              '1–3 mein se bataiye (Name, Birthday date, Note).',
            );
          }
          return const ProcessResult.assistantOnly(
            '1–4 mein se bataiye (Name, Amount, Date, Note).',
          );
        }
      }

      if (rSubPick != null) {
        if (rSubPick == 'task' && field == 'clientName') {
          await _state.updateState(
            userId,
            ChatFlowState(
              pendingAction: ChatFlowState.actionEditingConfirm,
              stepIndex: 0,
              pendingData: {
                'editingMode': 'value',
                'editingDraft': dmap,
                'editingField': 'clientName',
              },
            ),
          );
          return const ProcessResult.assistantOnly(
            'Client naam? (optional — khaali chhodne ke liye "skip")',
          );
        }
        final jumpIdx =
            FlowStepEngine.reminderStepIndexForEditField(rSubPick, field);
        if (jumpIdx >= 0) {
          var pd = Map<String, dynamic>.from(
            FlowStepEngine.normalizeData(dmap),
          );
          switch (field) {
            case 'taskTitle':
              pd.remove(FlowStepEngine.kTaskTitle);
              pd.remove('taskTitle');
              break;
            case 'name':
              pd.remove(FlowStepEngine.kName);
              pd.remove('clientName');
              pd.remove('nameLower');
              break;
            case 'date':
              pd.remove(FlowStepEngine.kDate);
              pd.remove('date');
              break;
            case 'time':
              pd.remove(FlowStepEngine.kTime);
              pd.remove('time');
              pd.remove('timeSkipped');
              break;
            case 'priority':
              pd.remove('priority');
              break;
            case 'note':
              pd.remove(FlowStepEngine.kNote);
              pd.remove('note');
              break;
            default:
              break;
          }
          pd['flowCategoryId'] = fcidPick;
          await _state.updateState(
            userId,
            ChatFlowState(
              currentCategory: 'reminder',
              currentSubcategory: rSubPick,
              flowCategoryId: fcidPick,
              pendingAction: ChatFlowState.actionCollecting,
              stepIndex: jumpIdx,
              pendingData: pd,
            ),
          );
          _log('EDIT_JUMP', {'field': field, 'stepIndex': jumpIdx});
          return ProcessResult.assistantOnly(
            FlowStepEngine.getNextQuestion(jumpIdx, 'reminder', rSubPick),
          );
        }
      }
      await _state.updateState(
        userId,
        ChatFlowState(
          pendingAction: ChatFlowState.actionEditingConfirm,
          stepIndex: 0,
          pendingData: {
            'editingMode': 'value',
            'editingDraft': dmap,
            'editingField': field,
          },
        ),
      );
      final prompt = switch (field) {
        'taskTitle' => 'Naya task?',
        'name' => 'Naya naam / client?',
        'amount' => 'Naya amount (₹)?',
        'date' => 'Nayi deadline? (kal 5pm, aaj, …)',
        'birthDate' => 'Nayi birthday date? (20-05, 20/05, 20 May)',
        'priority' => 'Nayi priority? (High / Medium / Low)',
        'note' => 'Nayi note?',
        'clientName' => 'Client naam?',
        _ => 'Value?',
      };
      return ProcessResult.assistantOnly(prompt);
    }
    final field = flow.pendingData['editingField'] as String? ?? 'name';
    final next = Map<String, dynamic>.from(dmap);
    final err = _applyEditValue(field, t, next);
    if (err != null) {
      return ProcessResult.assistantOnly(err);
    }
    final draft = draftFromMap(next);
    final fcidEd =
        next['flowCategoryId'] as String? ??
            flowCategoryIdFromActionTypes(draft.type, draft.subType);
    final fullMap = buildConfirmDraftMap(
      draft,
      flowCategoryId: fcidEd,
      stepData: next,
    );
    await _state.clearConfirmState(userId);
    _log('STATE_RESET', 'edit_value_done');
    return ProcessResult.inChatConfirm(
      draft,
      summary: formatConfirmSummary(fullMap, draft),
      confirmDraftMap: fullMap,
      aivyData: _quickRepliesAivy,
    );
  }

  String? _applyEditValue(
    String field,
    String text,
    Map<String, dynamic> d,
  ) {
    final s = text.trim();
    final fcid = (d['flowCategoryId'] as String? ?? '').trim();

    if (field == 'clientName' && fcid == 'reminder_task') {
      if (s.isEmpty ||
          s.toLowerCase() == 'skip' ||
          s.toLowerCase() == 'none') {
        d.remove('clientName');
        return null;
      }
      d['clientName'] = s;
      return null;
    }

    if (s.isEmpty) {
      return 'Kuch type karein.';
    }
    switch (field) {
      case 'taskTitle':
        if (s.length < 2) {
          return 'Task thoda lamba ho.';
        }
        d[FlowStepEngine.kTaskTitle] = s;
        d['taskTitle'] = s;
        return null;
      case 'name':
        if (s.length < 2) {
          return 'Naam thoda lamba ho.';
        }
        d['name'] = s;
        d['nameLower'] = normalizeName(s);
        return null;
      case 'amount':
        final a = double.tryParse(s.replaceAll(RegExp(r'[₹,\s]'), '')) ??
            extractInrAmountFromText(s);
        if (a == null || a <= 0) {
          return 'Valid amount bataiye.';
        }
        d['amount'] = a;
        return null;
      case 'date':
        if (fcid == 'reminder_task') {
          final combo = ReminderTimeParser.parseReminderDateStepAnswer(s);
          if (combo == null) {
            return 'Deadline clear nahi — kal 5pm, aaj, … phir se.';
          }
          d['date'] = combo.dateMs;
          d['time'] = combo.timeMinutes;
          d.remove('timeSkipped');
          return null;
        }
        if (fcid.startsWith('quotation_') ||
            fcid == 'followup_client' ||
            fcid == 'personal_task') {
          final combo = ReminderTimeParser.parseReminderDateStepAnswer(s);
          if (combo == null) {
            return 'Follow-up date/time clear nahi — kal 11:30am, kal 5pm, ya 20 May 11am try karein.';
          }
          final day = DateTime.fromMillisecondsSinceEpoch(combo.dateMs);
          final h = combo.timeMinutes ~/ 60;
          final m = combo.timeMinutes % 60;
          d['date'] = DateTime(day.year, day.month, day.day, h, m)
              .millisecondsSinceEpoch;
          return null;
        }
        final p = ReminderTimeParser.resolveDateDayForReminderFlow(s);
        if (p == null) {
          return 'Date clear nahi — phir se.';
        }
        d['date'] = p.millisecondsSinceEpoch;
        return null;
      case 'priority':
        d['priority'] = parseTaskPriorityFromUserInput(s);
        return null;
      case 'note':
        d['note'] = s;
        return null;
      case 'birthDate':
        final slash = RegExp(
          r'^(\d{1,2})[/-](\d{1,2})(?:[/-](\d{2,4}))?$',
        ).firstMatch(s);
        if (slash == null) {
          return 'Birthday date 20-05 ya 20/05 format me likhiye.';
        }
        final dd = int.tryParse(slash.group(1) ?? '');
        final mm = int.tryParse(slash.group(2) ?? '');
        final yyRaw = slash.group(3);
        final yy = yyRaw == null ? null : int.tryParse(yyRaw);
        if (dd == null || mm == null || dd < 1 || dd > 31 || mm < 1 || mm > 12) {
          return 'Birthday date valid nahi hai.';
        }
        if (yy != null) {
          final yOut = yy < 100 ? 2000 + yy : yy;
          d[FlowStepEngine.kBirthDate] =
              '${dd.toString().padLeft(2, '0')}-${mm.toString().padLeft(2, '0')}-$yOut';
        } else {
          d[FlowStepEngine.kBirthDate] =
              '${dd.toString().padLeft(2, '0')}-${mm.toString().padLeft(2, '0')}';
        }
        return null;
      default:
        return 'Unknown field.';
    }
  }

  Future<ProcessResult> _handleCollecting(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final cat = flow.currentCategory!;
    final sub = flow.currentSubcategory!;
    final fcid = flow.flowCategoryId ?? flowCategoryIdFor(cat, sub);

    if (cat == 'reports') {
      final q = t;
      _logCloudFallbackBlockCheck('reports_collect_cloudRun', flow);
      await _state.clearState(userId);
      _log('INTENT', 'reports_query');
      _log('FINAL_DATA', {'query': q});
      return ProcessResult.cloudRun(
        _reportsShortcutForSub(sub) ?? q,
        intent: 'query',
      );
    }

    final step = flow.stepIndex;
    if (FlowStepEngine.isFlowComplete(step, cat, sub, pendingData: flow.pendingData)) {
      _logCloudFallbackBlockCheck('collecting_flow_complete_none', flow);
      await _state.clearState(userId);
      return const ProcessResult.none();
    }

    final result = FlowStepEngine.applyAnswer(
      stepIndex: step,
      category: cat,
      sub: sub,
      pendingData: flow.pendingData,
      userInput: t,
    );

    if (result is FlowApplyInvalid) {
      if (_isUnrelatedInterrupt(t)) {
        await _state.updateState(
          userId,
          ChatFlowState(
            pendingAction: ChatFlowState.actionAwaitingContinue,
            stepIndex: 0,
            pendingData: {
              'resume': {
                'cat': cat,
                'sub': sub,
                'flowCategoryId': fcid,
                'step': step,
                'data': flow.pendingData,
              },
            },
          ),
        );
        return const ProcessResult.assistantOnly(
          'Aap alag cheez pooch rahe ho. Current flow jari rakhein?\nReply: Yes / Cancel',
        );
      }
      return ProcessResult.assistantOnly(result.message);
    }
    if (result is! FlowApplyOk) {
      return const ProcessResult.assistantOnly('Error.');
    }

    if (!result.done) {
      _log('STEP', result.nextStepIndex);
      await _state.updateState(
        userId,
        ChatFlowState(
          currentCategory: cat,
          currentSubcategory: sub,
          flowCategoryId: fcid,
          pendingAction: ChatFlowState.actionCollecting,
          stepIndex: result.nextStepIndex,
          pendingData: result.updatedData,
        ),
      );
      return ProcessResult.assistantOnly(
        FlowStepEngine.getNextQuestion(result.nextStepIndex, cat, sub),
      );
    }

    final fcidOut = result.updatedData['flowCategoryId'] as String? ?? fcid;
    final draft = _buildDraft(cat, sub, result.updatedData);
    final fullMap = buildConfirmDraftMap(
      draft,
      flowCategoryId: fcidOut,
      stepData: result.updatedData,
    );
    if (cat == 'payment' && sub == 'received') {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly(
        'Payment received ab **pending due chun kar** settle hota hai — + menu se dubara shuru karein.',
      );
    }
    final needClient = (cat == 'payment' &&
            (sub == 'due' || sub == 'followup')) ||
        (cat == 'followup' && sub == 'payment');
    if (needClient) {
      final blocker = await _ensureClientForPaymentMap(
        userId,
        fullMap,
        cat,
        sub,
        fcidOut,
      );
      if (blocker != null) {
        return blocker;
      }
    }
    if (cat == 'reminder') {
      if (!FlowStepEngine.isFlowComplete(
        FlowStepEngine.stepKeysFor(cat, sub).length,
        cat,
        sub,
        pendingData: fullMap,
      )) {
        _log('VALIDATION_FAIL', fullMap);
        await _state.clearConfirmState(userId);
        _log('STATE_RESET', 'draft_ready blocked');
        return const ProcessResult.assistantOnly(
          '⚠️ Reminder data incomplete — please sahi karein.',
        );
      }
    }
    await _state.clearState(userId);
    _log('INTENT', 'draft_ready');
    _log('FINAL_DATA', fullMap);
    final draftForConfirm = draftFromMap(fullMap);
    return ProcessResult.inChatConfirm(
      draftForConfirm,
      summary: formatConfirmSummary(fullMap, draftForConfirm),
      confirmDraftMap: fullMap,
      aivyData: _quickRepliesAivy,
    );
  }

  static bool _isUnrelatedInterrupt(String t) {
    final trimmed = t.trim();
    if (RegExp(r'^\d[\d,₹\s.]*$').hasMatch(trimmed) && trimmed.length < 18) {
      return false;
    }
    if (RegExp(
      r'^(amount|date|naam|name|note)\b',
      caseSensitive: false,
    ).hasMatch(trimmed)) {
      return false;
    }
    final w = t.split(RegExp(r'\s+'));
    if (w.length < 4) {
      return false;
    }
    if (t.contains('?') ||
        RegExp(
          r'^\s*also|anyway|btw|weather|order |report |kitna',
          caseSensitive: false,
        ).hasMatch(t)) {
      return true;
    }
    return w.length > 8;
  }

  Future<ProcessResult?> _tryPaymentSelectionList(
    String userId,
    String nameQuery, {
    String? rawNameToken,
    bool fromContextMemory = false,
  }) async {
    final token = (rawNameToken?.trim().isNotEmpty == true)
        ? rawNameToken!.trim()
        : nameQuery.trim();
    if (token.isEmpty) {
      return null;
    }
    final n = normalizeName(token);
    if (n.isEmpty) {
      return null;
    }
    final byDue = await _payments.searchOpenPaymentDuesByNameNormalized(
      userId,
      n,
    );
    if (byDue.isEmpty) {
      return null;
    }
    return _openPaymentDueRowsFromPaymentsListing(
      userId,
      byDue,
      fromContextMemory: fromContextMemory,
    );
  }

  /// Open `payments` dues only (no legacy), for name-based payment-received search.
  Future<ProcessResult?> _openPaymentDueRowsFromPaymentsListing(
    String userId,
    List<PaymentRecord> dues, {
    required bool fromContextMemory,
  }) async {
    if (dues.isEmpty) {
      return null;
    }
    final rows = <Map<String, dynamic>>[];
    for (final p in dues) {
      rows.add({
        'id': p.id,
        'source': 'firestore',
        'clientId': p.clientId,
        'name': p.clientName,
        'amount': p.amount,
        'remainingAmount': p.effectiveRemaining,
        'status': p.status,
        'date': p.dueDateMs,
        'subType': p.subType,
        'invoiceLabel': p.invoiceLabel,
      });
    }
    if (rows.length == 1) {
      final cid = (rows.first['clientId'] as String? ?? '').trim();
      final c = await _clients.getById(userId, cid);
      if (c == null) {
        return null;
      }
      return _beginPaymentDueSettlement(userId, c, rows.first);
    }
    final buf = StringBuffer();
    final proactive = await _proactiveOpenPaymentsLine(userId);
    if (proactive != null) {
      buf.writeln(proactive);
      buf.writeln();
    }
    final headName = (dues.first.clientName).trim();
    buf.writeln(
      headName.isNotEmpty
          ? '$headName ke pending dues:\n'
          : 'Pending dues:\n',
    );
    buf.writeln();
    buf.writeln('Kaunsi payment receive hui?\n');
    for (var i = 0; i < rows.length; i++) {
      buf.writeln(_formatPaymentRowLine(i + 1, rows[i], showClientName: true));
    }
    buf.writeln('\nNumber bhejein (1–${rows.length}).');
    await _state.updateState(
      userId,
      ChatFlowState(
        pendingAction: ChatFlowState.actionPendingSelection,
        selectionType: ChatFlowState.selectionPaymentUpdate,
        selectionList: rows,
        pendingSelection: true,
        stepIndex: 0,
        pendingData: {
          'fromContext': fromContextMemory,
          'fuzzyQuery': '',
        },
      ),
    );
    return ProcessResult.assistantOnly(buf.toString().trim());
  }

  /// Phase 6: nudge when open rows exist.
  Future<String?> _proactiveOpenPaymentsLine(String userId) async {
    final n = await _structured.countOpenPaymentActions(userId);
    if (n <= 0) {
      return null;
    }
    final sample = await _structured.sampleOpenPaymentClientNames(
      userId,
      maxNames: 2,
    );
    if (sample.isEmpty) {
      return 'Tip: aapke $n open payment row(s) pending hain — neeche se chuno.';
    }
    return 'Tip: $n open payment(s) (jaise ${sample.join(', ')}). ';
  }

  static bool _isAmbiguousPaymentVsReminder(String text) {
    final lower = text.toLowerCase();
    if (!RegExp(r'\b\d{3,6}\b').hasMatch(lower)) {
      return false;
    }
    if (!RegExp(r'\bko\b', caseSensitive: false).hasMatch(lower)) {
      return false;
    }
    final rem = RegExp(
      r'\b(yaad|remind|reminder|call|mulaakat)\b',
      caseSensitive: false,
    ).hasMatch(lower);
    final pay = RegExp(
      r'\b(dena|lena|payment|due|vasool|chuk|milna|milega)\b',
      caseSensitive: false,
    ).hasMatch(lower);
    return rem && pay;
  }

  String? _reportsShortcutForSub(String sub) {
    if (sub == 'status') {
      return 'Full business status';
    }
    return null;
  }

  static StructuredAction _buildDraft(
    String cat,
    String sub,
    Map<String, dynamic> m,
  ) {
    final n = FlowStepEngine.normalizeData(m);
    final name = (() {
      if (cat == 'reminder' && sub == 'task') {
        return (n['clientName'] ?? '').toString().trim();
      }
      return (n[FlowStepEngine.kName] ?? n['name'] ?? n['clientName'] ?? '')
          .toString()
          .trim();
    })();
    double? amount;
    final a = n[FlowStepEngine.kAmount] ?? n['amount'];
    if (a is num) {
      amount = a.toDouble();
    } else if (a is String) {
      amount = double.tryParse(a) ?? extractInrAmountFromText(a);
    }
    DateTime? date;
    final d = n[FlowStepEngine.kDate] ?? n['date'];
    if (cat == 'reminder') {
      if (d is int) {
        final raw = DateTime.fromMillisecondsSinceEpoch(d);
        final day = DateTime(raw.year, raw.month, raw.day);
        final tmin = n[FlowStepEngine.kTime] ?? n['time'];
        var min = 11 * 60;
        if (tmin is int) {
          min = tmin;
        }
        if (n['timeSkipped'] == true) {
          final em = raw.hour * 60 + raw.minute;
          if (em != 0) {
            min = em;
          }
        }
        final h = min ~/ 60;
        final mi = min % 60;
        date = DateTime(day.year, day.month, day.day, h, mi);
      } else if (d is String) {
        var parsed = ReminderTimeParser.resolveScheduledTimeFromPlainText(d);
        if (parsed != null) {
          final tmin = n[FlowStepEngine.kTime] ?? n['time'];
          if (tmin is int) {
            final h = tmin ~/ 60;
            final m0 = tmin % 60;
            final day = DateTime(
              parsed.year,
              parsed.month,
              parsed.day,
            );
            date = DateTime(day.year, day.month, day.day, h, m0);
          } else {
            date = parsed;
          }
        }
      }
    } else {
      if (d is int) {
        date = DateTime.fromMillisecondsSinceEpoch(d);
      } else if (d is String) {
        date = ReminderTimeParser.resolveScheduledTimeFromPlainText(d);
      }
    }
    if (cat == 'followup' && sub == 'payment') {
      amount = null;
    }
    if (cat == 'payment' && sub == 'followup') {
      amount = null;
    }
    return StructuredAction(
      type: structuredTypeFor(cat),
      subType: structuredSubTypeFor(cat, sub),
      name: name,
      nameLower: name.isNotEmpty ? normalizeName(name) : '',
      amount: amount,
      date: date,
      note: n[FlowStepEngine.kNote] as String? ?? n['note'] as String?,
      status: 'pending',
      createdAt: DateTime.now(),
    );
  }

  Future<void> _sendWhatsappEnsuringContactRow({
    required String userId,
    required String phone,
    required String message,
    String fallbackContactName = '',
  }) async {
    final p = phone.trim();
    final msg = WhatsappOutboundText.normalize(message);
    if (p.isEmpty || msg.isEmpty) {
      return;
    }
    final existing = await _contactBook.getContactByPhone(userId, p);
    final String inboxDisplayName;
    if (existing != null) {
      inboxDisplayName = existing.name.trim();
    } else {
      final n = fallbackContactName.trim().isEmpty
          ? 'WhatsApp contact'
          : fallbackContactName.trim();
      await _contactBook.addContact(
        ownerUid: userId,
        name: n,
        phone: p,
        notes: 'Chat se WhatsApp — auto-save',
      );
      inboxDisplayName = n;
    }
    await _waOut.sendOutboundToPhone(
      phone: p,
      message: msg,
      contactDisplayName: inboxDisplayName,
    );
  }

  static const Map<String, dynamic> _waContactConfirmQuick = <String, dynamic>{
    'quickReplies': ['Confirm — contact OK', 'Cancel'],
    'controlledFlow': true,
  };

  static const Map<String, dynamic> _waLangPickQuick = <String, dynamic>{
    'quickReplies': [
      'Hindi bhejein',
      'English bhejein',
      'Edit message',
      'Cancel',
    ],
    'controlledFlow': true,
  };

  bool _isWaGenericCancel(String low) {
    return low == 'cancel' || low == 'band';
  }

  bool _isWaContactConfirmYes(String raw, String low) {
    if (raw.contains('Confirm — contact OK')) {
      return true;
    }
    if (low.contains('confirm') && low.contains('contact')) {
      return true;
    }
    if (low == 'haan' ||
        low == 'haan.' ||
        low == 'yes' ||
        low == 'ok' ||
        low == 'theek' ||
        low == '1') {
      return true;
    }
    return false;
  }

  Future<ProcessResult> _handleWhatsappContactConfirm(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final low = t.toLowerCase().trim();
    if (_isWaGenericCancel(low)) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('WhatsApp send cancel.');
    }
    if (!_isWaContactConfirmYes(t, low)) {
      return ProcessResult.assistantOnly(
        'Samjhe nahi.\n\n'
        'Neeche **Confirm — contact OK** dabayein, ya **Cancel**.',
        aivyData: _waContactConfirmQuick,
      );
    }
    final msgHi = WhatsappOutboundText.normalize(
      '${flow.pendingData['messageHi'] ?? ''}',
    );
    if (msgHi.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('Message kho gaya — dubara likhein.');
    }
    var msgEn = '';
    try {
      final tr = waLineTranslator;
      if (tr != null) {
        msgEn = (await tr(msgHi)).trim();
      }
    } catch (_) {
      msgEn = '';
    }
    if (msgEn.isEmpty) {
      msgEn = msgHi;
    }
    await _state.updateState(
      userId,
      ChatFlowState(
        pendingAction: ChatFlowState.actionAwaitingWhatsappLangPick,
        pendingData: <String, dynamic>{
          ...Map<String, dynamic>.from(flow.pendingData),
          'messageHi': msgHi,
          'messageEn': msgEn,
        },
        stepIndex: 0,
      ),
    );
    final dn = '${flow.pendingData['displayName'] ?? ''}'.trim();
    final phone = '${flow.pendingData['phone'] ?? ''}'.trim();
    final buf = StringBuffer()
      ..writeln('Contact OK ✓ **$dn** ($phone)')
      ..writeln('')
      ..writeln('**Hindi / typed**')
      ..writeln(msgHi)
      ..writeln('')
      ..writeln('**Professional English**')
      ..writeln(msgEn)
      ..writeln('')
      ..writeln('Kaunsa version WhatsApp par bhejein? Edit se text badal sakte hain.');
    return ProcessResult.assistantOnly(
      buf.toString().trim(),
      aivyData: _waLangPickQuick,
    );
  }

  Future<ProcessResult> _handleWhatsappLangPick(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final raw = t.trim();
    final low = raw.toLowerCase();
    if (_isWaGenericCancel(low)) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('WhatsApp send cancel.');
    }
    if (low.contains('edit')) {
      final msgHi = WhatsappOutboundText.normalize(
        '${flow.pendingData['messageHi'] ?? ''}',
      );
      final token = DateTime.now().millisecondsSinceEpoch.toString();
      await _state.updateState(
        userId,
        ChatFlowState(
          pendingAction: ChatFlowState.actionAwaitingWhatsappSendMessage,
          pendingData: <String, dynamic>{
            'phone': flow.pendingData['phone'],
            'displayName': flow.pendingData['displayName'],
            'contactId': flow.pendingData['contactId'] ?? '',
            if (msgHi.isNotEmpty) 'prefillMessage': msgHi,
            if (msgHi.isNotEmpty) 'prefillToken': token,
          },
          stepIndex: 0,
        ),
      );
      return ProcessResult.assistantOnly(
        msgHi.isEmpty
            ? 'Theek — ab jo message WhatsApp par bhejna hai seedha likhiye.'
            : 'Theek — neeche wale box me message bhar diya hai; zarurat ho to edit karke bhejein.',
      );
    }
    var pickEnglish = false;
    var pickHindi = false;
    if (raw == 'English bhejein' || low == 'english bhejein') {
      pickEnglish = true;
    } else if (raw == 'Hindi bhejein' || low == 'hindi bhejein') {
      pickHindi = true;
    } else if (low.contains('english') && !low.contains('hindi')) {
      pickEnglish = true;
    } else if (low.contains('hindi') && !low.contains('english')) {
      pickHindi = true;
    }
    if (!pickHindi && !pickEnglish) {
      return ProcessResult.assistantOnly(
        'Samjhe nahi.\n\n'
        '**Hindi bhejein** ya **English bhejein** dabayein, ya Edit / Cancel.',
        aivyData: _waLangPickQuick,
      );
    }
    final phone = '${flow.pendingData['phone'] ?? ''}'.trim();
    final msgHi = WhatsappOutboundText.normalize(
      '${flow.pendingData['messageHi'] ?? ''}',
    );
    final msgEn = WhatsappOutboundText.normalize(
      '${flow.pendingData['messageEn'] ?? ''}',
    );
    final toSend = pickEnglish
        ? (msgEn.isNotEmpty ? msgEn : msgHi)
        : msgHi;
    final norm = WhatsappOutboundText.normalize(toSend);
    if (phone.isEmpty || norm.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('Data incomplete — dubara shuru karein.');
    }
    try {
      await _sendWhatsappEnsuringContactRow(
        userId: userId,
        phone: phone,
        message: norm,
        fallbackContactName: '${flow.pendingData['displayName'] ?? ''}',
      );
      await _state.clearState(userId);
      final label = pickEnglish ? 'English' : 'Hindi';
      final dn = '${flow.pendingData['displayName'] ?? ''}'.trim();
      return ProcessResult.assistantOnly(
        'WhatsApp bhej diya ($label): ${dn.isNotEmpty ? '$dn ' : ''}($phone).',
      );
    } catch (e) {
      return ProcessResult.assistantOnly('WhatsApp send fail: $e');
    }
  }

  Future<ProcessResult?> _tryGoogleWorkspaceIntents(
    String userId,
    String t,
  ) async {
    final cal = await _tryGoogleCalendarIntent(t);
    if (cal != null) {
      return cal;
    }
    final sh = await _tryGoogleSheetsIntent(userId, t);
    if (sh != null) {
      return sh;
    }
    final gm = await _tryGoogleGmailIntent(t);
    if (gm != null) {
      return gm;
    }
    return null;
  }

  Future<ProcessResult?> _tryGoogleCalendarIntent(String t) async {
    final parsed = GoogleCalendarIntentParser.tryParse(t);
    if (parsed == null) {
      return null;
    }
    try {
      final link = await GoogleCalendarClient.insertTimedEvent(
        summary: parsed.summary,
        startLocal: parsed.start,
        duration: parsed.duration,
      );
      final when = DateFormat('EEE d MMM, h:mm a').format(parsed.start);
      final tail = link.isNotEmpty ? '\n\nOpen: $link' : '';
      return ProcessResult.assistantOnly(
        'Google Calendar par event add ho gaya.\n'
        '**${parsed.summary}** — $when$tail',
      );
    } catch (e) {
      return ProcessResult.assistantOnly(
        'Calendar add nahi ho paya: $e\n\n'
        'More → **Allow Google extras** se permissions check karein.',
      );
    }
  }

  Future<ProcessResult?> _tryGoogleGmailIntent(String t) async {
    final parsed = GoogleGmailIntentParser.tryParse(t);
    if (parsed == null) {
      return null;
    }
    try {
      await GoogleGmailClient.sendPlainText(
        to: parsed.to,
        subject: parsed.subject,
        body: parsed.body,
      );
      return ProcessResult.assistantOnly(
        'Email bhej diya **${parsed.to}** (subject: ${parsed.subject}).',
      );
    } catch (e) {
      return ProcessResult.assistantOnly(
        'Mail nahi ja saka: $e\n\n'
        'More → **Allow Google extras** + Gmail scope check karein.',
      );
    }
  }

  Future<ProcessResult?> _tryGoogleSheetsIntent(String userId, String t) async {
    final parsed = GoogleSheetsIntentParser.tryParse(t);
    if (parsed == null) {
      return null;
    }
    final store = GoogleIntegrationStore();
    final sid = await store.getDefaultSpreadsheetId(userId);
    if (sid == null || sid.isEmpty) {
      return const ProcessResult.assistantOnly(
        'Pehle **More → Default Google Sheet ID** mein spreadsheet ID save karein '
        '(Sheets URL ke `/d/…/edit` wale beech ka hissa).\n\n'
        'Phir likhein: `sheet row: naam, phone, amount`',
      );
    }
    try {
      await GoogleSheetsClient.appendRow(
        spreadsheetId: sid,
        cells: parsed.cells,
      );
      return ProcessResult.assistantOnly(
        'Google Sheet mein ek row add ho gayi (${parsed.cells.length} columns).',
      );
    } catch (e) {
      return ProcessResult.assistantOnly(
        'Sheet update fail: $e\n\n'
        'Sheet ID, tab name **Sheet1**, aur permissions check karein.',
      );
    }
  }

  Future<ProcessResult?> _tryWhatsAppContactIntent(
    String userId,
    String t,
  ) async {
    if (!WhatsappContactIntentParser.looksLikeWhatsappSendIntent(t)) {
      return null;
    }
    final parsed = WhatsappContactIntentParser.tryParse(t);
    if (parsed == null) {
      return null;
    }
    final matches = await _contactBook.searchContactsByNameIncludingGoogle(
      userId,
      parsed.contactNameToken,
    );
    if (matches.length == 1) {
      final c = matches.first;
      final rawTail = parsed.messageTail?.trim();
      if (rawTail != null && rawTail.isNotEmpty) {
        final msg = WhatsappOutboundText.normalize(rawTail);
        if (msg.isNotEmpty) {
          await _state.updateState(
            userId,
            ChatFlowState(
              pendingAction: ChatFlowState.actionAwaitingWhatsappContactConfirm,
              pendingData: <String, dynamic>{
                'phone': c.phone,
                'displayName': c.name,
                'contactId': c.id,
                'messageHi': msg,
                'messageEn': '',
              },
              stepIndex: 0,
            ),
          );
          final buf = StringBuffer()
            ..writeln('**WhatsApp** → **${c.name}** (${c.phone})')
            ..writeln('')
            ..writeln('**Message (preview):**')
            ..writeln(msg)
            ..writeln('')
            ..writeln(
              'Pehle contact confirm karein — uske baad Hindi / English choose kar '
              'sakenge.',
            );
          return ProcessResult.assistantOnly(
            buf.toString().trim(),
            aivyData: const <String, dynamic>{
              'quickReplies': [
                'Confirm — contact OK',
                'Cancel',
              ],
              'controlledFlow': true,
            },
          );
        }
      }
      await _state.updateState(
        userId,
        ChatFlowState(
          pendingAction: ChatFlowState.actionAwaitingWhatsappSendMessage,
          pendingData: <String, dynamic>{
            'phone': c.phone,
            'displayName': c.name,
            'contactId': c.id,
          },
          stepIndex: 0,
        ),
      );
      return ProcessResult.assistantOnly(
        '${c.name} (${c.phone}) — kya message WhatsApp pe bhejna hai? Seedha likh dein.',
      );
    }
    if (matches.length > 1) {
      final buf = StringBuffer('Kaunsa contact?\n\n');
      final list = <Map<String, dynamic>>[];
      for (var i = 0; i < matches.length; i++) {
        buf.writeln('${i + 1}. ${matches[i].name} — ${matches[i].phone}');
        list.add(<String, dynamic>{
          'id': matches[i].id,
          'name': matches[i].name,
          'phone': matches[i].phone,
        });
      }
      buf.writeln('\nNumber bhejein (1–${matches.length}).');
      final preRaw = parsed.messageTail?.trim() ?? '';
      final pre = preRaw.isEmpty ? '' : WhatsappOutboundText.normalize(preRaw);
      await _state.updateState(
        userId,
        ChatFlowState(
          pendingAction: ChatFlowState.actionPendingSelection,
          selectionType: ChatFlowState.selectionContactWhatsApp,
          selectionList: list,
          pendingSelection: true,
          pendingData: <String, dynamic>{
            if (pre.isNotEmpty) 'prefillMessage': pre,
          },
        ),
      );
      return ProcessResult.assistantOnly(buf.toString().trim());
    }
    final preRaw = parsed.messageTail?.trim() ?? '';
    final pre = preRaw.isEmpty ? '' : WhatsappOutboundText.normalize(preRaw);
    await _state.updateState(
      userId,
      ChatFlowState(
        pendingAction: ChatFlowState.actionAwaitingWhatsappPhoneNumber,
        pendingData: <String, dynamic>{
          'guessName': parsed.contactNameToken,
          if (pre.isNotEmpty) 'prefillMessage': pre,
        },
        stepIndex: 0,
      ),
    );
    return ProcessResult.assistantOnly(
      '"${parsed.contactNameToken}" se koi contact match nahi hua.\n'
      'WhatsApp number **91XXXXXXXXXX** format me bhejein.',
    );
  }

  Future<ProcessResult> _handleContactWhatsappPick(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final list = flow.selectionList;
    if (list.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly(
        'List khaali — dubara try karein.',
      );
    }
    final idx = _selectionIndexFromText(t, list.length);
    if (idx == null) {
      return ProcessResult.assistantOnly(
        '1 se ${list.length} number bhejein.',
      );
    }
    final row = list[idx];
    final phone = '${row['phone'] ?? ''}'.trim();
    final name = '${row['name'] ?? ''}'.trim();
    final id = '${row['id'] ?? ''}'.trim();
    if (phone.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('Row invalid — dubara try karein.');
    }
    final preRaw = '${flow.pendingData['prefillMessage'] ?? ''}'.trim();
    final pre = preRaw.isEmpty ? '' : WhatsappOutboundText.normalize(preRaw);
    if (pre.isNotEmpty) {
      await _state.updateState(
        userId,
        ChatFlowState(
          pendingAction: ChatFlowState.actionAwaitingWhatsappContactConfirm,
          pendingData: <String, dynamic>{
            'phone': phone,
            'displayName': name,
            'contactId': id,
            'messageHi': pre,
            'messageEn': '',
          },
          stepIndex: 0,
        ),
      );
      final buf = StringBuffer()
        ..writeln('**WhatsApp** → **$name** ($phone)')
        ..writeln('')
        ..writeln('**Message (preview):**')
        ..writeln(pre)
        ..writeln('')
        ..writeln(
          'Pehle contact confirm karein — uske baad Hindi / English choose kar '
          'sakenge.',
        );
      return ProcessResult.assistantOnly(
        buf.toString().trim(),
        aivyData: _waContactConfirmQuick,
      );
    }
    await _state.updateState(
      userId,
      ChatFlowState(
        pendingAction: ChatFlowState.actionAwaitingWhatsappSendMessage,
        pendingData: <String, dynamic>{
          'phone': phone,
          'displayName': name,
          'contactId': id,
        },
        stepIndex: 0,
      ),
    );
    return ProcessResult.assistantOnly(
      '$name ($phone) — kya message WhatsApp pe bhejna hai?',
    );
  }

  Future<ProcessResult> _handleAwaitingWhatsappPhoneNumber(
    String userId,
    String t,
    ChatFlowState flow,
  ) async {
    final low = t.toLowerCase().trim();
    if (low == 'cancel' || low == 'band') {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('Theek — WhatsApp flow band.');
    }
    final p = ContactService.normalizeIndiaPhone(t);
    if (p == null) {
      return const ProcessResult.assistantOnly(
        'Number clear nahi — 91XXXXXXXXXX ya 10 digit Indian mobile try karein.',
      );
    }
    final guess = '${flow.pendingData['guessName'] ?? ''}'.trim();
    final preRaw = '${flow.pendingData['prefillMessage'] ?? ''}'.trim();
    final pre = preRaw.isEmpty ? '' : WhatsappOutboundText.normalize(preRaw);
    if (pre.isNotEmpty) {
      final dn = guess.isNotEmpty ? guess : 'Contact';
      await _state.updateState(
        userId,
        ChatFlowState(
          pendingAction: ChatFlowState.actionAwaitingWhatsappContactConfirm,
          pendingData: <String, dynamic>{
            'phone': p,
            'displayName': dn,
            'contactId': '',
            'messageHi': pre,
            'messageEn': '',
          },
          stepIndex: 0,
        ),
      );
      final buf = StringBuffer()
        ..writeln('**WhatsApp** → **$dn** ($p)')
        ..writeln('')
        ..writeln('**Message (preview):**')
        ..writeln(pre)
        ..writeln('')
        ..writeln(
          'Pehle contact confirm karein — uske baad Hindi / English choose kar '
          'sakenge.',
        );
      return ProcessResult.assistantOnly(
        buf.toString().trim(),
        aivyData: _waContactConfirmQuick,
      );
    }
    await _state.updateState(
      userId,
      ChatFlowState(
        pendingAction: ChatFlowState.actionAwaitingWhatsappSendMessage,
        pendingData: <String, dynamic>{
          'phone': p,
          'displayName': guess.isNotEmpty ? guess : 'Contact',
          'contactId': '',
        },
        stepIndex: 0,
      ),
    );
    return ProcessResult.assistantOnly(
      'Number: $p.\nAb WhatsApp message likhiye (ek message).',
    );
  }

  Future<ProcessResult> _handleAwaitingWhatsappSendMessage(
    String userId,
    String t,
    ChatFlowState flowState,
  ) async {
    final low = t.toLowerCase().trim();
    if (low == 'cancel' || low == 'band') {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly('Theek — flow band.');
    }
    if (t.trim().isEmpty) {
      return const ProcessResult.assistantOnly(
        'Message khali nahi — kuch likhiye.',
      );
    }
    final phone = '${flowState.pendingData['phone'] ?? ''}'.trim();
    if (phone.isEmpty) {
      await _state.clearState(userId);
      return const ProcessResult.assistantOnly(
        'State lost — dubara "Naam ko WhatsApp" se shuru karein.',
      );
    }
    try {
      final dn = '${flowState.pendingData['displayName'] ?? ''}'.trim();
      final norm = WhatsappOutboundText.normalize(t.trim());
      await _sendWhatsappEnsuringContactRow(
        userId: userId,
        phone: phone,
        message: norm,
        fallbackContactName: dn,
      );
      await _state.clearState(userId);
      final label = dn.isNotEmpty ? '$dn ($phone)' : phone;
      return ProcessResult.assistantOnly('WhatsApp bhej diya: $label');
    } catch (e) {
      return ProcessResult.assistantOnly(
        'WhatsApp send nahi ho paya: $e\n'
        'Cancel likh kar band kar sakte hain.',
      );
    }
  }

  static int? _selectionIndexFromText(String raw, int len) {
    if (len < 1) {
      return null;
    }
    final t = raw.trim();
    final n = int.tryParse(t);
    if (n != null && n >= 1 && n <= len) {
      return n - 1;
    }
    final low = t.toLowerCase();
    if (RegExp(
      r'^(first|pehla|pehle|1st|#1|ek)\b',
      caseSensitive: false,
    ).hasMatch(low)) {
      return 0;
    }
    if (RegExp(
      r'^(second|dusra|doosra|2nd|#2|do)\b',
      caseSensitive: false,
    ).hasMatch(low)) {
      return len > 1 ? 1 : null;
    }
    if (RegExp(
      r'^(third|teesra|3rd|#3|teen)\b',
      caseSensitive: false,
    ).hasMatch(low)) {
      return len > 2 ? 2 : null;
    }
    if (RegExp(
      r'^(last|aakhri|aakhiri|antim|final|sabse\s*last)\b',
      caseSensitive: false,
    ).hasMatch(low)) {
      return len - 1;
    }
    return null;
  }

  static String formatHumanSummary(StructuredAction d, {String? title}) {
    final fcid = flowCategoryIdFromActionTypes(d.type, d.subType);
    final m = buildConfirmDraftMap(d, flowCategoryId: fcid);
    if (title != null &&
        title.isNotEmpty &&
        fcid.startsWith('payment_')) {
      return formatPaymentSummary(
        d,
        flowCategoryId: fcid,
        titleOverride: title,
      );
    }
    return formatConfirmSummary(m, d);
  }

  Future<String> saveDraft({
    required String userId,
    required StructuredAction action,
  }) {
    if (action.id != null) {
      return _structured
          .setStatus(userId, action.id!, 'completed')
          .then((_) => action.id!);
    }
    return _structured.save(action, userId: userId);
  }
}