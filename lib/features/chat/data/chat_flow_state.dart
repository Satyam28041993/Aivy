import 'package:flutter/foundation.dart';

/// Session under [users/{uid}/meta/chat_state] — conversational controlled flow.
@immutable
class ChatFlowState {
  const ChatFlowState({
    this.currentCategory,
    this.currentSubcategory,
    this.flowCategoryId,
    this.pendingAction,
    this.pendingData = const {},
    this.stepIndex = 0,
    this.pendingSelection,
    this.selectionType,
    this.selectionList = const [],
    this.lastActionId,
    this.lastActionType,
    this.lastEntity,
  });

  final String? currentCategory;
  final String? currentSubcategory;

  /// Lock: e.g. [reminder_call], [payment_due] — set when subcategory is chosen.
  final String? flowCategoryId;

  final String? pendingAction;
  final Map<String, dynamic> pendingData;
  /// 0-based index into the field list for this category:sub.
  final int stepIndex;
  final bool? pendingSelection;
  final String? selectionType;
  final List<Map<String, dynamic>> selectionList;
  /// Last confirmed structured action (for undo), Phase 5.
  final String? lastActionId;
  /// e.g. `created` | `status_completed`
  final String? lastActionType;

  /// Phase 6: last resolved client (e.g. for payment) — `{ "name", "type" }`.
  final Map<String, dynamic>? lastEntity;

  static const String selectionPaymentUpdate = 'payment_update';
  static const String selectionPaymentNameDisambig = 'payment_name_disambig';
  static const String selectionClientPick = 'client_pick';
  static const String selectionOrderProcessPick = 'order_process_pick';
  static const String selectionOrderDispatchPick = 'order_dispatch_pick';
  static const String selectionOrderClientPick = 'order_client_pick';
  static const String selectionQuotationFollowupPick = 'quotation_followup_pick';
  static const String selectionContactWhatsApp = 'contact_whatsapp_pick';

  /// After resolving a contact / number — next line is the outbound WhatsApp text.
  static const String actionAwaitingWhatsappSendMessage =
      'awaiting_whatsapp_send_message';

  /// Single contact + template message — user confirms contact before language pick.
  static const String actionAwaitingWhatsappContactConfirm =
      'awaiting_whatsapp_contact_confirm';

  /// Hindi vs English outbound choice (+ Edit / Cancel).
  static const String actionAwaitingWhatsappLangPick =
      'awaiting_whatsapp_lang_pick';

  /// No Firestore match — user must paste a phone number.
  static const String actionAwaitingWhatsappPhoneNumber =
      'awaiting_whatsapp_phone_number';

  /// "Payment received" without context — naam vs pending list.
  static const String actionAwaitingPaymentReceivedChoice =
      'awaiting_payment_received_choice';

  /// Payment received: user picked option 1 — next message is client name (dues search only).
  static const String actionAwaitingPaymentReceivedClientName =
      'awaiting_payment_received_client_name';

  /// Linked due chosen — ask received amount (then date).
  static const String actionAwaitingPaymentSettlementAmount =
      'awaiting_payment_settlement_amount';

  static const String actionAwaitingPaymentSettlementDate =
      'awaiting_payment_settlement_date';

  /// After "Payment due" — list all / one client / add new.
  static const String actionAwaitingPaymentDueChoice =
      'awaiting_payment_due_choice';

  /// User chose client-specific pending list; next message is client name.
  static const String actionAwaitingPaymentDueClientName =
      'awaiting_payment_due_client_name';

  /// Payment Follow-up: choose existing client list or new client.
  static const String actionAwaitingPaymentFollowupChoice =
      'awaiting_payment_followup_choice';

  /// Payment Follow-up: awaiting amount after client is resolved.
  static const String actionAwaitingFollowupAmount =
      'awaiting_followup_amount';

  /// Payment Follow-up: awaiting due date after amount is collected.
  static const String actionAwaitingFollowupDate =
      'awaiting_followup_date';

  /// Payment Follow-up: awaiting new client name entry.
  static const String actionAwaitingFollowupNewClientName =
      'awaiting_followup_new_client_name';
  static const String actionAwaitingOrderUpdateMode = 'awaiting_order_update_mode';
  static const String actionAwaitingOrderClientName = 'awaiting_order_client_name';
  static const String actionAwaitingOrderProcessStage =
      'awaiting_order_process_stage';
  static const String actionAwaitingOrderDispatchDueChoice =
      'awaiting_order_dispatch_due_choice';
  static const String actionAwaitingOrderDispatchAmount =
      'awaiting_order_dispatch_amount';
  static const String actionAwaitingOrderDispatchReceivedAmount =
      'awaiting_order_dispatch_received_amount';
  static const String actionAwaitingOrderDispatchTermDays =
      'awaiting_order_dispatch_term_days';

  /// Back-compat with Phase 3 field name in Firestore.
  int get fieldStep => stepIndex;

  static const String actionIdle = 'idle';
  static const String actionCategoryMenu = 'category_menu';
  static const String actionSelectingSub = 'selecting_subcategory';
  static const String actionCollecting = 'collecting_fields';
  static const String actionAwaitingDisambig = 'awaiting_disambiguation';
  static const String actionAwaitingFreeConfirm = 'awaiting_free_text_confirm';
  static const String actionPendingSelection = 'pending_selection';
  static const String actionAwaitingContinue = 'awaiting_continue';
  static const String actionAwaitingChatConfirm = 'awaiting_chat_confirm';
  static const String actionEditingConfirm = 'editing_confirm';
  static const String actionAwaitingNewClientName = 'awaiting_new_client_name';
  static const String actionAwaitingCreateClientConfirm =
      'awaiting_create_client_confirm';

  static List<Map<String, dynamic>> _parseSelectionList(Object? raw) {
    if (raw is! List) {
      return const [];
    }
    final out = <Map<String, dynamic>>[];
    for (final e in raw) {
      if (e is Map) {
        out.add(Map<String, dynamic>.from(e));
      }
    }
    return out;
  }

  static ChatFlowState fromFirestore(Map<String, dynamic>? m) {
    if (m == null) {
      return const ChatFlowState();
    }
    final raw = m['pendingData'];
    Map<String, dynamic> data = {};
    if (raw is Map) {
      data = Map<String, dynamic>.from(raw);
    }
    String? s(String? x) {
      final t = x?.trim() ?? '';
      return t.isEmpty ? null : t;
    }

    final fromStep = (m['stepIndex'] as num?)?.toInt();
    final fromLegacy = (m['fieldStep'] as num?)?.toInt();
    final step = fromStep ?? fromLegacy ?? 0;

    final ps = m['pendingSelection'];
    bool? pendingSel;
    if (ps is bool) {
      pendingSel = ps;
    } else if (ps is String) {
      pendingSel = ps == 'true' || ps == '1';
    }

    final paRaw = m['pendingAction'];
    String? pendingActionStr;
    if (paRaw is String) {
      pendingActionStr = s(paRaw);
    } else if (paRaw != null) {
      pendingActionStr = s(paRaw.toString());
    }

    Object? le = m['lastEntity'];
    Map<String, dynamic>? ent;
    if (le is Map) {
      ent = Map<String, dynamic>.from(le);
    }

    return ChatFlowState(
      currentCategory: s(m['currentCategory'] as String?),
      currentSubcategory: s(m['currentSubcategory'] as String?),
      flowCategoryId: s(m['flowCategoryId'] as String?),
      pendingAction: pendingActionStr,
      pendingData: data,
      stepIndex: step,
      pendingSelection: pendingSel,
      selectionType: s(m['selectionType'] as String?),
      selectionList: _parseSelectionList(m['selectionList']),
      lastActionId: s(m['lastActionId'] as String?),
      lastActionType: s(m['lastActionType'] as String?),
      lastEntity: ent,
    );
  }

  Map<String, Object?> toPatchForMerge() {
    final o = <String, Object?>{
      'currentCategory': currentCategory,
      'currentSubcategory': currentSubcategory,
      'pendingAction': pendingAction,
      'pendingData': pendingData,
      'fieldStep': stepIndex,
      'stepIndex': stepIndex,
      'pendingSelection': pendingSelection,
      'selectionType': selectionType,
      'selectionList': selectionList,
      'lastActionId': lastActionId,
      'lastActionType': lastActionType,
    };
    if (flowCategoryId != null) {
      o['flowCategoryId'] = flowCategoryId;
    }
    if (lastEntity != null) {
      o['lastEntity'] = lastEntity;
    }
    return o;
  }
}
