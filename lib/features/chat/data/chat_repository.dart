import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../../../core/notifications/notification_service.dart';
import '../../dashboard/models/order_record.dart';
import '../../dashboard/models/quotation_record.dart';
import '../../reminders/data/reminder_repository.dart';
import '../../reminders/models/reminder_item.dart';
import '../../tasks/models/task_item.dart';
import '../models/chat_session.dart';
import '../models/meeting_session_summary.dart';
import '../models/memory_entry_summary.dart';


class ChatRepository {
  ChatRepository({
    FirebaseFirestore? firestore,
    NotificationService? notificationService,
    ReminderRepository? reminderRepository,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       // Retained for dependency injection; reminder scheduling was removed in Phase 2.
       _notificationService =
           notificationService ?? NotificationService.instance,
       _reminderRepository = reminderRepository ?? ReminderRepository();

  final FirebaseFirestore _firestore;
  // ignore: unused_field
  final NotificationService _notificationService;
  final ReminderRepository _reminderRepository;

  CollectionReference<Map<String, dynamic>> _chats(String userId) {
    return _firestore.collection('users').doc(userId).collection('chats');
  }

  CollectionReference<Map<String, dynamic>> _tasks(String userId) {
    return _firestore.collection('users').doc(userId).collection('tasks');
  }

  CollectionReference<Map<String, dynamic>> _reminders(String userId) {
    return _firestore.collection('users').doc(userId).collection('reminders');
  }

  CollectionReference<Map<String, dynamic>> _quotations(String userId) {
    return _firestore.collection('users').doc(userId).collection('quotations');
  }

  CollectionReference<Map<String, dynamic>> _orders(String userId) {
    return _firestore.collection('users').doc(userId).collection('orders');
  }

  CollectionReference<Map<String, dynamic>> _memory(String userId) {
    return _firestore.collection('users').doc(userId).collection('memory');
  }

  CollectionReference<Map<String, dynamic>> _sessions(String userId) {
    return _firestore.collection('users').doc(userId).collection('sessions');
  }

  DocumentReference<Map<String, dynamic>> _chatStateRef(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('meta')
        .doc('chat_state');
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

  static const _duplicateReminderTimeWindowMs = 5 * 60 * 1000;

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

}
