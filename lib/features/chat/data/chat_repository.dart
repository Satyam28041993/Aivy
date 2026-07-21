import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import '../../../core/notifications/notification_service.dart';
import '../../dashboard/models/client_insights_summary.dart';
import '../../dashboard/models/daily_summary.dart';
import '../../dashboard/models/entry_summary.dart';
import '../../dashboard/models/order_record.dart';
import '../../dashboard/models/quotation_record.dart';
import '../../reminders/data/reminder_repository.dart';
import '../../reminders/models/action_required_item.dart';
import '../../reminders/models/reminder_item.dart';
import '../../structured_actions/utils/name_normalize.dart';
import '../../tasks/models/task_item.dart';
import '../models/aivy_ai_response.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/entry_quick_outcome.dart';
import '../models/meeting_session_summary.dart';
import '../models/memory_entry_summary.dart';
import 'chat_flow_state.dart';
import '../utils/aivy_response_formatter.dart';
import '../utils/extract_inr_amount.dart';
import 'voice_file_upload.dart'
    if (dart.library.io) 'voice_file_upload_io.dart';

/// [AivyAiResponse.data.analyticsKind] values that carry [rows] for chat table UI.
const Set<String> _analyticsKindsWithTableRows = {
  'client_rank_business',
  'client_rank_pending',
  'week_payment_followup_list',
  'risky_clients_list',
  'overdue_payments_list',
  'followup_today_list',
  'pending_orders_list',
  'quotation_line_items',
};

class ChatRepository {
  ChatRepository({
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
    NotificationService? notificationService,
    ReminderRepository? reminderRepository,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _storage = storage ?? FirebaseStorage.instance,
       // Retained for dependency injection; reminder scheduling was removed in Phase 2.
       _notificationService =
           notificationService ?? NotificationService.instance,
       _reminderRepository = reminderRepository ?? ReminderRepository();

  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage;
  // ignore: unused_field
  final NotificationService _notificationService;
  final ReminderRepository _reminderRepository;

  /// Uploads a local voice recording to
  /// `users/{userId}/voice/{entryId}.m4a` and returns the download URL.
  Future<String> uploadVoiceFile({
    required String userId,
    required String entryId,
    required String localFilePath,
  }) {
    return uploadVoiceToStorage(
      storage: _storage,
      userId: userId,
      entryId: entryId,
      localFilePath: localFilePath,
    );
  }

  /// Marks a voice-only entry complete so it does not stay in `processing`.
  Future<void> completeVoiceEntry({
    required String userId,
    required String entryId,
  }) async {
    await _entries(userId).doc(entryId).update({
      'status': 'completed',
      'contextType': 'voice',
      'summary': 'Voice message',
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  CollectionReference<Map<String, dynamic>> _chats(String userId) {
    return _firestore.collection('users').doc(userId).collection('chats');
  }

  CollectionReference<Map<String, dynamic>> _chatMessages(
    String userId,
    String chatId,
  ) {
    return _chats(userId).doc(chatId).collection('messages');
  }

  CollectionReference<Map<String, dynamic>> _entries(String userId) {
    return _firestore.collection('users').doc(userId).collection('entries');
  }

  CollectionReference<Map<String, dynamic>> _tasks(String userId) {
    return _firestore.collection('users').doc(userId).collection('tasks');
  }

  CollectionReference<Map<String, dynamic>> _reminders(String userId) {
    return _firestore.collection('users').doc(userId).collection('reminders');
  }

  CollectionReference<Map<String, dynamic>> _payments(String userId) {
    return _firestore.collection('users').doc(userId).collection('payments');
  }

  CollectionReference<Map<String, dynamic>> _quotations(String userId) {
    return _firestore.collection('users').doc(userId).collection('quotations');
  }

  CollectionReference<Map<String, dynamic>> _orders(String userId) {
    return _firestore.collection('users').doc(userId).collection('orders');
  }

  Future<String> createOrder({
    required String userId,
    required String clientName,
    required double amount,
    String? note,
  }) async {
    final name = clientName.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(clientName, 'clientName', 'must not be empty');
    }
    if (amount <= 0) {
      throw ArgumentError.value(amount, 'amount', 'must be > 0');
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final ref = _orders(userId).doc();
    await ref.set({
      'clientName': name,
      'clientNameLower': normalizeName(name),
      'amount': amount,
      'status': 'pending',
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtMs': nowMs,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': nowMs,
    });
    return ref.id;
  }

  Future<String> createQuotation({
    required String userId,
    required String clientName,
    required double amount,
    required int followUpDateMs,
    String? note,
  }) async {
    final name = clientName.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(clientName, 'clientName', 'must not be empty');
    }
    if (amount <= 0) {
      throw ArgumentError.value(amount, 'amount', 'must be > 0');
    }
    if (followUpDateMs <= 0) {
      throw ArgumentError.value(
        followUpDateMs,
        'followUpDateMs',
        'must be > 0',
      );
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final ref = _quotations(userId).doc();
    await ref.set({
      'clientName': name,
      'clientNameLower': normalizeName(name),
      'amount': amount,
      'followUpDateMs': followUpDateMs,
      'status': 'pending',
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtMs': nowMs,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': nowMs,
    });
    return ref.id;
  }

  Future<void> updateQuotationFollowUp({
    required String userId,
    required String quotationId,
    required int followUpDateMs,
    String? note,
  }) async {
    final patch = <String, dynamic>{
      'followUpDateMs': followUpDateMs,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
    };
    if (note != null && note.trim().isNotEmpty) {
      patch['followUpNote'] = note.trim();
    }
    await _quotations(userId).doc(quotationId).set(patch, SetOptions(merge: true));
  }

  Future<List<OrderRecord>> fetchPendingOrdersForClient(
    String userId,
    String clientName,
  ) async {
    final norm = normalizeName(clientName);
    if (norm.isEmpty) {
      return const <OrderRecord>[];
    }
    final all = await _orders(userId)
        .where('status', isEqualTo: 'pending')
        .limit(500)
        .get();
    final out = <OrderRecord>[];
    for (final doc in all.docs) {
      final row = OrderRecord.fromDoc(doc);
      final rowNorm = normalizeName(row.clientName ?? '');
      if (rowNorm == norm && row.isPending) {
        out.add(row);
      }
    }
    out.sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
    return out;
  }

  Future<List<OrderRecord>> fetchPendingOrders(
    String userId, {
    int limit = 500,
  }) async {
    final snap = await _orders(userId)
        .where('status', isEqualTo: 'pending')
        .limit(limit)
        .get();
    final out = snap.docs
        .map(OrderRecord.fromDoc)
        .where((o) => o.isPending)
        .toList(growable: false);
    out.sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
    return out;
  }

  Future<void> updateOrderProcessStage({
    required String userId,
    required String orderId,
    required String processStage,
  }) async {
    final stage = processStage.trim();
    if (stage.isEmpty) {
      throw ArgumentError.value(processStage, 'processStage', 'must not be empty');
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await _orders(userId).doc(orderId).set({
      'processStage': stage,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': nowMs,
    }, SetOptions(merge: true));
  }

  Future<void> markOrderDispatched({
    required String userId,
    required String orderId,
    int? paymentTermDays,
    int? paymentDueDateMs,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final patch = <String, dynamic>{
      'status': 'dispatched',
      'dispatchDate': FieldValue.serverTimestamp(),
      'dispatchedAt': FieldValue.serverTimestamp(),
      'dispatchedAtMs': nowMs,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': nowMs,
    };
    if (paymentTermDays != null && paymentTermDays > 0) {
      patch['paymentTermDays'] = paymentTermDays;
    }
    if (paymentDueDateMs != null && paymentDueDateMs > 0) {
      patch['paymentDueDateMs'] = paymentDueDateMs;
      patch['paymentDueDate'] = Timestamp.fromMillisecondsSinceEpoch(
        paymentDueDateMs,
      );
      patch['paymentStatus'] = 'pending';
    }
    await _orders(userId).doc(orderId).set(patch, SetOptions(merge: true));
  }

  CollectionReference<Map<String, dynamic>> _memory(String userId) {
    return _firestore.collection('users').doc(userId).collection('memory');
  }

  CollectionReference<Map<String, dynamic>> _sessions(String userId) {
    return _firestore.collection('users').doc(userId).collection('sessions');
  }

  CollectionReference<Map<String, dynamic>> _records(String userId) {
    return _firestore.collection('users').doc(userId).collection('records');
  }

  DocumentReference<Map<String, dynamic>> _chatStateRef(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('meta')
        .doc('chat_state');
  }

  /// Parses a monetary amount from free text (last plausible number wins).
  static double? extractAmountFromText(String text) =>
      extractInrAmountFromText(text);

  /// Append-only ledger for in-chat confirms. Reports and debugging read
  /// `users/{uid}/records`.
  Future<String> appendBusinessLedgerRecord({
    required String userId,
    required Map<String, dynamic> fields,
  }) async {
    final ref = _records(userId).doc();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await ref.set({
      ...fields,
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtMs': nowMs,
    });
    if (kDebugMode) {
      debugPrint('SAVED ID: ${ref.id}');
    }
    return ref.id;
  }

  /// Recent ledger rows (newest first). Same collection chat confirms write to.
  Stream<List<Map<String, dynamic>>> watchBusinessLedgerRecords(
    String userId, {
    int limit = 80,
  }) {
    return _records(userId)
        .orderBy('createdAtMs', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map(
                (d) => <String, dynamic>{
                  ...d.data(),
                  'id': d.id,
                },
              )
              .toList(growable: false),
        );
  }

  /// After a quotation is saved, we offer scheduling a follow-up on the next turn.
  Future<void> setPendingQuotationFollowUp({
    required String userId,
    required String sourceEntryId,
    required String clientName,
  }) async {
    final label = clientName.trim();
    if (label.isEmpty) {
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await _chatStateRef(userId).set({
      'pendingQuotationFollowUp': {
        'sourceEntryId': sourceEntryId,
        'clientName': label,
        'createdAtMs': nowMs,
      },
    }, SetOptions(merge: true));
  }

  Future<void> clearPendingQuotationFollowUp(String userId) async {
    await _chatStateRef(userId).set({
      'pendingQuotationFollowUp': FieldValue.delete(),
    }, SetOptions(merge: true));
  }

  Future<PendingQuotationFollowUp?> readPendingQuotationFollowUp(
    String userId,
  ) async {
    final snap = await _chatStateRef(userId).get();
    final data = snap.data();
    if (data == null) {
      return null;
    }
    final raw = data['pendingQuotationFollowUp'];
    if (raw is! Map) {
      return null;
    }
    final map = Map<String, dynamic>.from(raw);
    final client = (map['clientName'] as String? ?? '').trim();
    final entryId = (map['sourceEntryId'] as String? ?? '').trim();
    if (client.isEmpty || entryId.isEmpty) {
      return null;
    }
    return PendingQuotationFollowUp(
      sourceEntryId: entryId,
      clientName: client,
      createdAtMs: (map['createdAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  /// Synced via [meta/chat_state] so web + mobile stay on the same thread when desired.
  Stream<String?> watchActiveChatId(String userId) {
    return _chatStateRef(userId).snapshots().map((snap) {
      final raw = snap.data()?['activeChatId'];
      if (raw is String && raw.trim().isNotEmpty) {
        return raw.trim();
      }
      return null;
    });
  }

  /// Live conversational flow snapshot (`pendingAction`, `pendingData`, etc.).
  Stream<ChatFlowState> watchChatFlowState(String userId) {
    return _chatStateRef(userId).snapshots().map((snap) {
      return ChatFlowState.fromFirestore(snap.data());
    });
  }

  /// One-shot flow state (same document as [watchChatFlowState]); used between
  /// consecutive routing layers to avoid mismatched snapshots.
  Future<ChatFlowState> fetchChatFlowState(String userId) async {
    final snap = await _chatStateRef(userId).get();
    return ChatFlowState.fromFirestore(snap.data());
  }

  Future<void> setActiveChatId(String userId, String chatId) async {
    await _chatStateRef(userId).set({
      'activeChatId': chatId,
    }, SetOptions(merge: true));
  }

  Stream<List<ChatSession>> watchChats(String userId) {
    return _chats(userId)
        .orderBy('updatedAtMs', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map(ChatSession.fromDoc).toList());
  }

  /// Live meeting sessions under `users/{uid}/sessions`.
  Stream<List<MeetingSessionSummary>> watchMeetingSessions(
    String userId, {
    int limit = 50,
  }) {
    return _sessions(userId)
        .orderBy('createdAtMs', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map(MeetingSessionSummary.fromDoc)
              .toList(growable: false),
        );
  }

  /// Live memory index under `users/{uid}/memory` (excludes empty ids).
  Stream<List<MemoryEntrySummary>> watchUserMemory(
    String userId, {
    int limit = 100,
  }) {
    return _memory(userId)
        .orderBy('createdAtMs', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map(MemoryEntrySummary.fromDoc)
              .toList(growable: false),
        );
  }

  Future<void> saveMeetingSession({
    required String userId,
    required String entryId,
    required String chatId,
    required int durationMs,
    required String transcriptPreview,
    required String summary,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await _sessions(userId).add({
      'entryId': entryId,
      'chatId': chatId,
      'durationMs': durationMs,
      'transcriptPreview': transcriptPreview,
      'summary': summary.trim(),
      'type': 'meeting',
      'createdAtMs': nowMs,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<String> createChat(String userId, {String title = 'New chat'}) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final ref = _chats(userId).doc();
    final safeTitle = title.trim().isEmpty ? 'New chat' : title.trim();
    await ref.set({
      'title': safeTitle,
      'createdAtMs': nowMs,
      'updatedAtMs': nowMs,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await setActiveChatId(userId, ref.id);
    return ref.id;
  }

  /// Points [activeChatId] at an existing chat or creates the first one.
  Future<String> ensureActiveChatSession(String userId) async {
    final meta = await _chatStateRef(userId).get();
    final active = (meta.data()?['activeChatId'] as String?)?.trim();
    if (active != null && active.isNotEmpty) {
      final exists = await _chats(userId).doc(active).get();
      if (exists.exists) {
        return active;
      }
    }
    final recent = await _chats(userId)
        .orderBy('updatedAtMs', descending: true)
        .limit(1)
        .get();
    if (recent.docs.isNotEmpty) {
      final id = recent.docs.first.id;
      await setActiveChatId(userId, id);
      return id;
    }
    return createChat(userId);
  }

  /// Removes the chat document and all messages. If it was the active thread,
  /// switches to another recent chat or creates a new one.
  Future<void> deleteChat(String userId, String chatId) async {
    final trimmed = chatId.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final meta = await _chatStateRef(userId).get();
    final wasActive =
        (meta.data()?['activeChatId'] as String?)?.trim() == trimmed;

    final messages = _chatMessages(userId, trimmed);
    while (true) {
      final snap = await messages.limit(500).get();
      if (snap.docs.isEmpty) {
        break;
      }
      final batch = _firestore.batch();
      for (final d in snap.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();
    }

    await _chats(userId).doc(trimmed).delete();

    if (!wasActive) {
      return;
    }

    final recent = await _chats(userId)
        .orderBy('updatedAtMs', descending: true)
        .limit(1)
        .get();
    if (recent.docs.isNotEmpty) {
      await setActiveChatId(userId, recent.docs.first.id);
    } else {
      await createChat(userId);
    }
  }

  Future<void> trySetChatTitleIfDefault({
    required String userId,
    required String chatId,
    required String userText,
  }) async {
    final ref = _chats(userId).doc(chatId);
    final snap = await ref.get();
    if (!snap.exists) {
      return;
    }
    final title = ((snap.data()?['title'] as String?) ?? '').trim();
    if (title.isNotEmpty && title.toLowerCase() != 'new chat') {
      return;
    }
    var t = userText.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.isEmpty) {
      return;
    }
    final preview = t.length > 48 ? '${t.substring(0, 45)}…' : t;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await ref.set({
      'title': preview,
      'updatedAtMs': nowMs,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  CollectionReference<Map<String, dynamic>> _dailySummaries(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('daily_summary');
  }

  /// Live view of the daily AI plan for [date] (local calendar day).
  /// Emits `null` when the document does not exist yet.
  Stream<DailySummary?> watchDailySummary(String userId, DateTime date) {
    final key = DailySummary.dateKey(date);
    return _dailySummaries(userId).doc(key).snapshots().map((snap) {
      if (!snap.exists) {
        return null;
      }
      return DailySummary.fromDoc(snap);
    });
  }

  /// Persists a freshly generated daily plan. Overwrites any existing
  /// document for the same calendar day.
  Future<void> saveDailySummary({
    required String userId,
    required DateTime date,
    required String summary,
    required List<String> bulletPoints,
    required String assistantReply,
    required int todayTaskCount,
    required int overdueTaskCount,
    required int upcomingReminderCount,
  }) async {
    final key = DailySummary.dateKey(date);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await _dailySummaries(userId).doc(key).set({
      'date': key,
      'summary': summary,
      'bulletPoints': bulletPoints,
      'assistantReply': assistantReply,
      'generatedAt': FieldValue.serverTimestamp(),
      'generatedAtMs': nowMs,
      'todayTaskCount': todayTaskCount,
      'overdueTaskCount': overdueTaskCount,
      'upcomingReminderCount': upcomingReminderCount,
    });
  }

  Stream<List<ChatMessage>> watchChatMessages(
    String userId,
    String chatId,
  ) {
    return _chatMessages(userId, chatId)
        .orderBy('createdAtMs')
        .snapshots()
        .map((snapshot) {
          final list = snapshot.docs.map(ChatMessage.fromDoc).toList();
          return _dedupeNearIdenticalMessages(list);
        });
  }

  /// Drops back-to-back identical bubbles (same entry, role, and text within a
  /// short window) so retried writes or race conditions do not duplicate the UI.
  static List<ChatMessage> _dedupeNearIdenticalMessages(
    List<ChatMessage> input,
  ) {
    if (input.length < 2) {
      return input;
    }
    final out = <ChatMessage>[];
    ChatMessage? lastKept;
    for (final m in input) {
      if (lastKept != null &&
          lastKept.entryId != null &&
          lastKept.entryId == m.entryId &&
          lastKept.role == m.role &&
          lastKept.text == m.text &&
          (m.createdAtMs - lastKept.createdAtMs).abs() < 5000) {
        continue;
      }
      out.add(m);
      lastKept = m;
    }
    return out;
  }

  static String? _intentFieldForAssistantMessage(AivyAiResponse response) {
    final intent = response.intent;
    if (intent == 'job_dispatch' || intent == 'payment_due') {
      return intent;
    }
    if (intent == 'order_dispatched') {
      return 'order_dispatched';
    }
    return null;
  }

  Stream<List<EntrySummary>> watchRecentEntries(
    String userId, {
    int limit = 30,
  }) {
    return _entries(userId)
        .orderBy('createdAtMs', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) => snapshot.docs.map(EntrySummary.fromDoc).toList());
  }

  Stream<List<TaskItem>> watchPendingTasks(String userId, {int limit = 200}) {
    return _tasks(userId)
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAtMs', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) => snapshot.docs.map(TaskItem.fromDoc).toList());
  }

  Stream<List<ReminderItem>> watchUpcomingReminders(
    String userId, {
    int limit = 100,
  }) {
    return _reminders(userId)
        .where('status', isEqualTo: 'pending')
        .orderBy('scheduledTimeMs')
        .limit(limit)
        .snapshots()
        .map((snapshot) {
          debugPrint('AIVY_REMINDER_FETCH: ${snapshot.docs.length}');
          return snapshot.docs.map(ReminderItem.fromDoc).toList();
        });
  }

  /// Live view of pending follow-up reminders generated by the Smart
  /// Follow-up Engine. Kept separate from [watchUpcomingReminders] so the
  /// dashboard can render a dedicated "Pending Follow-ups" section.
  Stream<List<ReminderItem>> watchPendingFollowUps(
    String userId, {
    int limit = 50,
  }) {
    return _reminders(userId)
        .where('status', isEqualTo: 'pending')
        .where('isFollowUp', isEqualTo: true)
        .orderBy('scheduledTimeMs')
        .limit(limit)
        .snapshots()
        .map((snapshot) => snapshot.docs.map(ReminderItem.fromDoc).toList());
  }

  /// Quotations saved under `users/{uid}/quotations` (newest first).
  Stream<List<QuotationRecord>> watchQuotations(
    String userId, {
    int limit = 500,
  }) {
    return _quotations(userId)
        .orderBy('createdAtMs', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(QuotationRecord.fromDoc)
              .toList(growable: false),
        );
  }

  Future<List<QuotationRecord>> fetchRecentQuotations(
    String userId, {
    int days = 30,
    int limit = 80,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cutoffMs = nowMs - Duration(days: days).inMilliseconds;
    final snap = await _quotations(userId)
        .where('createdAtMs', isGreaterThanOrEqualTo: cutoffMs)
        .orderBy('createdAtMs', descending: true)
        .limit(limit)
        .get();
    return snap.docs.map(QuotationRecord.fromDoc).toList(growable: false);
  }

  /// Business orders under `users/{uid}/orders` (newest first in stream).
  Stream<List<OrderRecord>> watchOrders(
    String userId, {
    int limit = 500,
  }) {
    return _orders(userId)
        .limit(limit)
        .snapshots()
        .map((snapshot) {
          final list = snapshot.docs
              .map(OrderRecord.fromDoc)
              .toList(growable: false);
          list.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
          return list;
        });
  }

  Future<List<ReminderItem>> fetchDuePendingReminders(
    String userId, {
    int limit = 20,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final snapshot = await _reminders(userId)
        .where('status', isEqualTo: 'pending')
        .where('scheduledTimeMs', isLessThanOrEqualTo: nowMs)
        .orderBy('scheduledTimeMs')
        .limit(limit)
        .get();

    return snapshot.docs.map(ReminderItem.fromDoc).toList(growable: false);
  }

  /// One-shot fetch of pending tasks. Used by the agent nudge service at
  /// app launch so we can compute proactive insights without waiting for
  /// the live stream to settle.
  Future<List<TaskItem>> fetchPendingTasks(
    String userId, {
    int limit = 200,
  }) async {
    final snapshot = await _tasks(userId)
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAtMs', descending: true)
        .limit(limit)
        .get();

    return snapshot.docs.map(TaskItem.fromDoc).toList(growable: false);
  }

  /// One-shot fetch of reminders whose scheduled time has already passed
  /// but that have not been triggered yet. These are the reminders the
  /// user missed while the app was closed.
  Future<List<ReminderItem>> fetchOverdueReminders(
    String userId, {
    int limit = 50,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final snapshot = await _reminders(userId)
        .where('status', isEqualTo: 'pending')
        .where('scheduledTimeMs', isLessThan: nowMs)
        .orderBy('scheduledTimeMs')
        .limit(limit)
        .get();

    return snapshot.docs.map(ReminderItem.fromDoc).toList(growable: false);
  }

  /// Returns recent `client` entries that have not yet had a follow-up
  /// generated. Used by the Smart Follow-up Engine to decide what to nudge.
  /// [maxAgeHours] caps how far back we look (default 7 days).
  Future<List<ClientEntrySnapshot>> fetchClientEntriesNeedingFollowUp(
    String userId, {
    int maxAgeHours = 24 * 7,
    int limit = 40,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cutoffMs = nowMs - maxAgeHours * Duration.millisecondsPerHour;
    try {
      final snapshot = await _entries(userId)
          .where('category', isEqualTo: 'client')
          .where('createdAtMs', isGreaterThanOrEqualTo: cutoffMs)
          .orderBy('createdAtMs', descending: true)
          .limit(limit)
          .get();

      return snapshot.docs
          .map(ClientEntrySnapshot.fromDoc)
          .where((entry) => entry.followUpCreatedAtMs == null)
          .toList(growable: false);
    } on FirebaseException catch (e) {
      if (e.code == 'failed-precondition') {
        debugPrint(
          'ChatRepository: follow-up query failed precondition (index); '
          'returning empty list.',
        );
        return const [];
      }
      rethrow;
    }
  }

  /// Returns true when any reminder (pending or triggered) already exists
  /// for [entryId] so we never create duplicate follow-ups.
  Future<bool> hasFollowUpForEntry({
    required String userId,
    required String entryId,
  }) async {
    final existing = await _reminders(userId)
        .where('sourceEntryId', isEqualTo: entryId)
        .where('isFollowUp', isEqualTo: true)
        .limit(1)
        .get();
    return existing.docs.isNotEmpty;
  }

  /// Reads the opaque "passive nudge" throttle doc used by
  /// [NotificationService] to avoid spamming the user. Returns null if
  /// no state has been written yet.
  Future<Map<String, dynamic>?> readNudgeState(String userId) async {
    final snap = await _firestore
        .collection('users')
        .doc(userId)
        .collection('meta')
        .doc('nudge_state')
        .get();
    return snap.data();
  }

  /// Persists the latest passive nudge timestamp / daily count so the
  /// throttle survives app restarts.
  Future<void> writeNudgeState({
    required String userId,
    required int lastSentMs,
    required int countToday,
    required String dayKey,
  }) async {
    await _firestore
        .collection('users')
        .doc(userId)
        .collection('meta')
        .doc('nudge_state')
        .set({
          'lastSentMs': lastSentMs,
          'countToday': countToday,
          'dayKey': dayKey,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  /// Precomputed business snapshot (`client_stats` roll-up + live payment totals).
  Stream<ClientInsightsSummary?> watchClientInsights(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('meta')
        .doc('client_insights')
        .snapshots()
        .map((snap) {
          if (!snap.exists) {
            return null;
          }
          return ClientInsightsSummary.fromDoc(snap);
        });
  }

  Future<void> markRemindersTriggered({
    required String userId,
    required List<String> reminderIds,
  }) async {
    if (reminderIds.isEmpty) {
      return;
    }

    final batch = _firestore.batch();
    for (final reminderId in reminderIds) {
      batch.update(_reminders(userId).doc(reminderId), {
        'status': 'triggered',
        'triggeredAt': FieldValue.serverTimestamp(),
      });
    }

    await batch.commit();
  }

  Future<String> addMessage({
    required String userId,
    required String chatId,
    required ChatRole role,
    required String text,
    String? entryId,
    ChatMessageType type = ChatMessageType.text,
    String? audioUrl,
    int? durationMs,
    String? transcript,
    TranscriptStatus? transcriptStatus,
    String? intent,
    bool isError = false,
  }) async {
    final doc = _chatMessages(userId, chatId).doc();
    final now = DateTime.now().millisecondsSinceEpoch;
    final data = <String, dynamic>{
      'role': role.value,
      'text': text.trim(),
      'entryId': entryId,
      'type': type.value,
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtMs': now,
    };

    if (audioUrl != null) {
      data['audioUrl'] = audioUrl;
    }
    if (durationMs != null) {
      data['durationMs'] = durationMs;
    }
    if (transcript != null) {
      data['transcript'] = transcript;
    }
    if (transcriptStatus != null) {
      data['transcriptStatus'] = transcriptStatus.value;
    }
    final w = intent?.trim();
    if (w != null && w.isNotEmpty) {
      data['intent'] = w;
    }
    if (isError) {
      data['isError'] = true;
    }

    await doc.set(data);
    await _touchChatSession(userId, chatId, bumpMs: now);
    return doc.id;
  }

  Future<void> _touchChatSession(
    String userId,
    String chatId, {
    required int bumpMs,
  }) async {
    await _chats(userId).doc(chatId).set({
      'updatedAtMs': bumpMs,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Updates an existing voice message with transcription text/status once
  /// the backend has returned a result. Safe to call repeatedly: missing
  /// documents simply no-op via Firestore's merge behavior on [update].
  Future<void> updateMessageTranscript({
    required String userId,
    required String chatId,
    required String messageId,
    String? transcript,
    required TranscriptStatus status,
  }) async {
    final data = <String, dynamic>{'transcriptStatus': status.value};
    if (transcript != null) {
      data['transcript'] = transcript;
    }
    await _chatMessages(userId, chatId).doc(messageId).update(data);
  }

  static const _duplicateReminderTimeWindowMs = 5 * 60 * 1000;

  /// Lowercases, trims, drops clock / time-of-day phrases, and strips common
  /// reminder prefixes so two user phrasings match on core intent.
  static String _normalizeReminderCoreIntent(String raw) {
    var s = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    s = _stripClockTimePhrasesForDuplicateCheck(s);
    s = _stripReminderIntentBoilerplate(s);
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _stripClockTimePhrasesForDuplicateCheck(String s) {
    var out = s;
    final patterns = <RegExp>[
      RegExp(r'\bat\s+\d{1,2}(?::[0-5]\d)?\s*(am|pm)\b', caseSensitive: false),
      RegExp(r'\bby\s+\d{1,2}(?::[0-5]\d)?\s*(am|pm)\b', caseSensitive: false),
      RegExp(r'\b\d{1,2}(?::[0-5]\d)?\s*(am|pm)\b', caseSensitive: false),
      RegExp(r'\b([01]?\d|2[0-3]):[0-5]\d\b'),
      RegExp(r'\b(at|by)\s+([01]?\d|2[0-3]):[0-5]\d\b'),
      RegExp(r"\b(o'clock|oclock|noon|midnight)\b"),
      RegExp(r'\b(in the morning|in the afternoon|in the evening|at night)\b'),
    ];
    for (final re in patterns) {
      out = out.replaceAll(re, ' ');
    }
    return out;
  }

  static String _stripReminderIntentBoilerplate(String s) {
    var out = s.trim();
    out = out
        .replaceFirst(
          RegExp(
            r'^(please\s+|can you\s+|could you\s+|kindly\s+)?'
            r'(set(\s+a)?\s+reminder(\s+for|\s+to)?|reminder:)\s+',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    out = out
        .replaceFirst(
          RegExp(
            r'^(please\s+|can you\s+|could you\s+|kindly\s+)?'
            r'(remind(er)?(\s+me)?(\s+to)?)\s+',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    return out;
  }

  /// Whether a pending reminder already exists for the same user on the same
  /// local calendar day as [scheduledTime], with [sourceText] matching core
  /// intent after normalization and scheduled times within ±5 minutes.
  Future<bool> hasPendingReminderDuplicateSameDay({
    required String userId,
    required String sourceText,
    required DateTime scheduledTime,
  }) async {
    final localScheduled = scheduledTime.toLocal();
    final start = DateTime(
      localScheduled.year,
      localScheduled.month,
      localScheduled.day,
    );
    final end = start.add(const Duration(days: 1));
    final startMs = start.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;
    final snap = await _reminders(userId)
        .where('status', isEqualTo: 'pending')
        .where('scheduledTimeMs', isGreaterThanOrEqualTo: startMs)
        .where('scheduledTimeMs', isLessThan: endMs)
        .limit(50)
        .get();

    final targetMs = localScheduled.millisecondsSinceEpoch;
    final sourceCore = _normalizeReminderCoreIntent(sourceText);

    for (final doc in snap.docs) {
      final data = doc.data();
      final msg = data['message'] as String? ?? '';
      final existingMs = (data['scheduledTimeMs'] as num?)?.toInt() ?? 0;
      if (existingMs == 0) {
        continue;
      }

      final existingCore = _normalizeReminderCoreIntent(msg);
      if (existingCore != sourceCore) {
        continue;
      }

      if ((existingMs - targetMs).abs() <= _duplicateReminderTimeWindowMs) {
        return true;
      }
    }
    return false;
  }

  /// Marks an entry complete and appends a single assistant bubble — used for
  /// local intents (reminder / quotation) without calling [aivyProcess].
  Future<void> completeEntryWithLocalAssistantOnly({
    required String userId,
    required String chatId,
    required String entryId,
    required String assistantText,
    String contextType = 'local_intent',
    Map<String, dynamic>? aivyData,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final batch = _firestore.batch();
    final entryRef = _entries(userId).doc(entryId);
    final assistantRef = _chatMessages(userId, chatId).doc();

    batch.update(entryRef, {
      'status': 'completed',
      'contextType': contextType,
      'assistantReply': assistantText.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    final msg = <String, dynamic>{
      'role': ChatRole.assistant.value,
      'text': assistantText.trim(),
      'entryId': entryId,
      'type': ChatMessageType.text.value,
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtMs': nowMs,
    };
    if (aivyData != null && aivyData.isNotEmpty) {
      msg['aivyData'] = aivyData;
    }
    batch.set(assistantRef, msg);

    batch.set(_chats(userId).doc(chatId), {
      'updatedAtMs': nowMs,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await batch.commit();
  }

  Future<String> createEntry({
    required String userId,
    required String rawInput,
    String source = 'text',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final doc = await _entries(userId).add({
      'source': source,
      'rawInput': rawInput.trim(),
      'status': 'processing',
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtMs': now,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    return doc.id;
  }

  Future<void> completeEntryWithAgentActivation({
    required String userId,
    required String chatId,
    required String entryId,
    required AivyAiResponse response,
    String? userRawInput,
    /// Google Cloud TTS MP3 URL (stored under users/{uid}/tts/).
    String? assistantTtsUrl,
  }) async {
    debugPrint(
      'AGENT MODE: persisting entry + chat message; reminders → Firestore when present',
    );

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final entryRef = _entries(userId).doc(entryId);
    final assistantMessageRef = _chatMessages(userId, chatId).doc();
    final batch = _firestore.batch();

    final clientTrimmed = response.clientName.trim();
    final clientForStore = clientTrimmed.isEmpty
        ? null
        : formatClientDisplayName(clientTrimmed);
    final clientNorm = clientForStore?.toLowerCase();

    final uiAssistantText = userReplyOnlyForChat(response);
    final uiIntent = _intentFieldForAssistantMessage(response);
    Map<String, dynamic>? aivyDataForMessage;
    if (response.intent == 'select_order_for_dispatch' &&
        response.data != null) {
      aivyDataForMessage = Map<String, dynamic>.from(response.data!);
    } else if (response.intent == 'analytics_query' && response.data != null) {
      final m = response.data!;
      final kind = m['analyticsKind']?.toString();
      if (kind == 'payment_due_list') {
        aivyDataForMessage = {
          'analyticsKind': kind,
          'rows': m['rows'],
          'totalAmount': m['totalAmount'],
          'windowLabel': m['windowLabel'],
          'count': m['count'],
          'clientFilterNoMatch': m['clientFilterNoMatch'],
          'paymentQueryUserText': m['paymentQueryUserText'],
        };
      } else if (kind == 'dispatch_line_items') {
        aivyDataForMessage = {
          'analyticsKind': kind,
          'rows': m['rows'],
          'windowLabel': m['windowLabel'],
          'count': m['count'],
        };
      } else if (kind == 'daily_status_summary' && m['dailySummarySnapshot'] != null) {
        aivyDataForMessage = {
          'analyticsKind': kind,
          'dailySummarySnapshot': m['dailySummarySnapshot'],
        };
      } else if (_analyticsKindsWithTableRows.contains(kind) &&
          m['rows'] is List) {
        aivyDataForMessage = {
          'analyticsKind': kind,
          'rows': m['rows'],
          'totalAmount': m['totalAmount'],
          'windowLabel': m['windowLabel'],
          'count': m['count'],
          'paymentQueryUserText': m['paymentQueryUserText'],
        };
      }
    }

    final ttsTrimmed = assistantTtsUrl?.trim();
    if (ttsTrimmed != null && ttsTrimmed.isNotEmpty) {
      aivyDataForMessage = {
        ...?aivyDataForMessage,
        'ttsAudioUrl': ttsTrimmed,
      };
    }

    final reminderMaps = response.reminderSuggestions
        .map((item) => item.toJson())
        .toList(growable: false);

    batch.update(entryRef, {
      'status': 'completed',
      'intent': response.intent,
      'jobRecord': response.jobRecord.toJson(),
      'paymentRecord': response.paymentRecord.toJson(),
      'contextType': response.contextType,
      'category': response.category,
      'memoryCategory': response.memoryCategory,
      'clientName': clientForStore,
      'clientNameNormalized': clientNorm,
      'summary': response.summary,
      'keyPoints': response.keyPoints,
      'assistantReply': uiAssistantText,
      'actionItems': response.actionItems,
      'followUpSuggestions': response.followUpSuggestions
          .map((item) => item.toJson())
          .toList(growable: false),
      'reminderSuggestions': reminderMaps,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    batch.set(assistantMessageRef, {
      'role': ChatRole.assistant.value,
      'text': uiAssistantText,
      'entryId': entryId,
      'type': ChatMessageType.text.value,
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtMs': nowMs,
      if (uiIntent != null) 'intent': uiIntent,
      if (aivyDataForMessage != null) 'aivyData': aivyDataForMessage,
    });

    batch.set(_chats(userId).doc(chatId), {
      'updatedAtMs': nowMs,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await batch.commit();

    if (response.reminderSuggestions.isNotEmpty) {
      try {
        final snippet = (userRawInput ?? '').trim();
        final persisted = await _reminderRepository.persistAiReminderSuggestions(
          userId: userId,
          entryId: entryId,
          suggestions: response.reminderSuggestions,
          sourceSnippet: snippet.isEmpty ? null : snippet,
        );
        for (final row in persisted) {
          final s = row.suggestion;
          final rt = (s.reminderType ?? '').trim().toLowerCase();
          final type = rt == 'payment_followup' || rt == 'manual_payment'
              ? 'followup'
              : 'task';
          final subType = rt.isNotEmpty ? rt : 'aivy_chat';
          final clientLabel = (s.displayClientName ?? '').trim().isNotEmpty
              ? s.displayClientName!.trim()
              : s.title.trim();
          await appendBusinessLedgerRecord(
            userId: userId,
            fields: {
              'type': type,
              'subType': subType,
              'flowCategoryId': 'aivy_ai_reminder',
              'clientName': clientLabel,
              'dueDate': Timestamp.fromDate(row.scheduledAt.toLocal()),
              'dueDateMs': row.scheduledAt.millisecondsSinceEpoch,
              'note': snippet.isEmpty ? s.title.trim() : snippet,
              'status': 'pending',
              'lastActionType': 'reminder_created',
              'savedDocId': row.id,
              'sourceCollection': 'reminders',
            },
          );
        }
      } catch (e, st) {
        debugPrint(
          'ChatRepository: persist AI reminders / ledger failed: $e\n$st',
        );
      }
    }
  }

  Future<void> patchEntryRawInput({
    required String userId,
    required String entryId,
    required String rawInput,
  }) async {
    final t = rawInput.trim();
    if (t.isEmpty) {
      return;
    }
    await _entries(userId).doc(entryId).update({
      'rawInput': t,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> failEntry({
    required String userId,
    required String entryId,
    required String reason,
  }) async {
    await _entries(userId).doc(entryId).update({
      'status': 'failed',
      'error': reason,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Smart reminder popup: pending reminders with [scheduledTimeMs] / [remindAt]
  /// at or before now+24h, plus all [overdue] payment rows. Merged and sorted
  /// (overdue → today → upcoming). Reminders linked to a payment id are deduped
  /// when that payment is already in the fetch.
  Future<List<ActionRequiredItem>> fetchImportantReminders(
    String userId, {
    int limitPayments = 50,
    int limitReminders = 80,
  }) async {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final horizonMs = nowMs + const Duration(hours: 24).inMilliseconds;
    var paymentRows = <ActionRequiredItem>[];
    var reminderRows = <ActionRequiredItem>[];

    try {
      final paySnap = await _payments(userId)
          .where('status', whereIn: ['overdue', 'pending', 'partial_pending'])
          .limit(limitPayments)
          .get();
      paymentRows = paySnap.docs
          .map(ActionRequiredItem.fromPaymentDoc)
          .toList(growable: false);
    } on FirebaseException catch (e) {
      debugPrint('ChatRepository: fetchImportantReminders payments: $e');
    }

    try {
      final remSnap = await _reminders(userId)
          .where('status', isEqualTo: 'pending')
          .where('scheduledTimeMs', isLessThanOrEqualTo: horizonMs)
          .orderBy('scheduledTimeMs')
          .limit(limitReminders)
          .get();
      reminderRows = remSnap.docs
          .map(ActionRequiredItem.fromReminderDoc)
          .toList(growable: false);
    } on FirebaseException catch (e) {
      if (e.code == 'failed-precondition') {
        debugPrint(
          'ChatRepository: fetchImportantReminders composite query failed; '
          'falling back to client filter: $e',
        );
        try {
          final remSnap = await _reminders(userId)
              .where('status', isEqualTo: 'pending')
              .limit(120)
              .get();
          reminderRows = remSnap.docs
              .map(ActionRequiredItem.fromReminderDoc)
              .where((r) => r.dueOrScheduleMs <= horizonMs)
              .toList();
        } catch (e2, st) {
          debugPrint('ChatRepository: fetchImportantReminders fallback: $e2\n$st');
        }
      } else {
        debugPrint('ChatRepository: fetchImportantReminders reminders: $e');
      }
    }

    return ActionRequiredItem.mergeDedupe(paymentRows, reminderRows);
  }

  /// Marks a payment as collected (mirrors server `aivyProcess` paid shape).
  /// Also marks any linked pending reminder for this payment as triggered.
  Future<void> markPaymentAsPaid({
    required String userId,
    required String paymentId,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await _payments(userId).doc(paymentId).set({
      'status': 'received',
      'receivedAt': FieldValue.serverTimestamp(),
      'receivedAtMs': nowMs,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': nowMs,
    }, SetOptions(merge: true));
    final link = await _reminders(userId)
        .where('paymentId', isEqualTo: paymentId)
        .limit(8)
        .get();
    var wrote = 0;
    final batch = _firestore.batch();
    for (final d in link.docs) {
      final st = d.data()['status'] as String? ?? '';
      if (st != 'pending') {
        continue;
      }
      wrote++;
      batch.update(d.reference, {
        'status': 'triggered',
        'triggeredAt': FieldValue.serverTimestamp(),
      });
    }
    if (wrote > 0) {
      await batch.commit();
    }
  }

  /// Pushes a reminder by one day (scheduled fields used across the app).
  Future<void> pushReminderByOneDay({
    required String userId,
    required String reminderId,
  }) async {
    final ref = _reminders(userId).doc(reminderId);
    final snap = await ref.get();
    if (!snap.exists) {
      return;
    }
    final data = snap.data()!;
    final oldMs = (data['scheduledTimeMs'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    final newTime = DateTime.fromMillisecondsSinceEpoch(oldMs)
        .add(const Duration(days: 1));
    final m = newTime.millisecondsSinceEpoch;
    await ref.update({
      'scheduledTimeMs': m,
      'scheduledTime': Timestamp.fromDate(newTime),
      'remindAt': Timestamp.fromDate(newTime),
      'dueDateMs': m,
      'pushedByOneDayAt': FieldValue.serverTimestamp(),
    });
  }

  /// Extends a payment's due by one day and syncs a linked pending reminder if any.
  Future<void> pushPaymentDueByOneDay({
    required String userId,
    required String paymentId,
  }) async {
    final pref = _payments(userId).doc(paymentId);
    final psnap = await pref.get();
    if (!psnap.exists) {
      return;
    }
    final data = psnap.data()!;
    var dueMs = (data['dueDateMs'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    final newTime =
        DateTime.fromMillisecondsSinceEpoch(dueMs).add(const Duration(days: 1));
    dueMs = newTime.millisecondsSinceEpoch;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final clearOverdue = dueMs > nowMs;
    final prevSt = (data['status'] as String? ?? '').trim().toLowerCase();
    await pref.update({
      'dueDateMs': dueMs,
      'dueDate': Timestamp.fromMillisecondsSinceEpoch(dueMs),
      'dueDateIso': DateTime.fromMillisecondsSinceEpoch(
        dueMs,
        isUtc: true,
      ).toLocal().toIso8601String(),
      'pushedByOneDayAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': nowMs,
      if (clearOverdue && prevSt == 'overdue') 'status': 'pending',
    });
    final link = await _reminders(userId)
        .where('paymentId', isEqualTo: paymentId)
        .limit(4)
        .get();
    for (final d in link.docs) {
      final st = d.data()['status'] as String? ?? '';
      if (st == 'pending') {
        await pushReminderByOneDay(
          userId: userId,
          reminderId: d.id,
        );
        break;
      }
    }
  }

  /// Dismiss a reminder (Done on non-payment rows).
  Future<void> markReminderDone({
    required String userId,
    required String reminderId,
  }) async {
    await _reminders(userId).doc(reminderId).update({
      'status': 'triggered',
      'triggeredAt': FieldValue.serverTimestamp(),
    });
    await NotificationService.instance.cancelReminderNotification(reminderId);
  }

  Future<void> markTaskDone({
    required String userId,
    required String taskId,
  }) async {
    await _tasks(userId).doc(taskId).update({
      'status': 'completed',
      'completedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Fields written on the entry when processing completes (for Home quick UI).
  Future<EntryQuickOutcome?> readEntryQuickOutcome(
    String userId,
    String entryId,
  ) async {
    final snap = await _entries(userId).doc(entryId).get();
    if (!snap.exists) {
      return null;
    }
    final d = snap.data()!;
    return EntryQuickOutcome(
      assistantReply: (d['assistantReply'] as String? ?? '').trim(),
      contextType: (d['contextType'] as String? ?? '').trim(),
      memoryCategory: (d['memoryCategory'] as String? ?? '').trim(),
      reminderSuggestionCount: (d['reminderSuggestions'] as List?)?.length ?? 0,
    );
  }
}

class PendingQuotationFollowUp {
  const PendingQuotationFollowUp({
    required this.sourceEntryId,
    required this.clientName,
    required this.createdAtMs,
  });

  final String sourceEntryId;
  final String clientName;
  final int createdAtMs;
}

/// Minimal projection of an `entries` document used by the Smart Follow-up
/// Engine. Intentionally scoped to only the fields we need to decide
/// whether to generate a follow-up reminder.
class ClientEntrySnapshot {
  const ClientEntrySnapshot({
    required this.id,
    required this.rawInput,
    required this.summary,
    required this.createdAtMs,
    required this.followUpCreatedAtMs,
  });

  final String id;
  final String rawInput;
  final String summary;
  final int createdAtMs;
  final int? followUpCreatedAtMs;

  factory ClientEntrySnapshot.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    return ClientEntrySnapshot(
      id: doc.id,
      rawInput: (data['rawInput'] as String? ?? '').trim(),
      summary: (data['summary'] as String? ?? '').trim(),
      createdAtMs: (data['createdAtMs'] as num?)?.toInt() ?? 0,
      followUpCreatedAtMs: (data['followUpCreatedAtMs'] as num?)?.toInt(),
    );
  }
}
