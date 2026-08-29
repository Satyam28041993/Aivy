import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../../../core/firebase/firebase_session.dart';
import '../models/agent_models.dart';

/// Client for the agent backend.
///
/// Turns go through the `aivyAgent` callable; the conversation itself is read
/// straight from Firestore, so a reply appears through the stream rather than
/// being returned to the caller and injected by hand.
class AgentService {
  AgentService({
    FirebaseFunctions? functions,
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _functions = functions ?? FirebaseSession.functions,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseSession.auth;

  final FirebaseFunctions _functions;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  String? _cachedTimezone;

  CollectionReference<Map<String, dynamic>> _chats(String userId) {
    return _firestore.collection('users').doc(userId).collection('agent_chats');
  }

  CollectionReference<Map<String, dynamic>> _messages(
    String userId,
    String chatId,
  ) {
    return _chats(userId).doc(chatId).collection('messages');
  }

  // -------------------------------------------------------------------------
  // Streams
  // -------------------------------------------------------------------------

  /// Live conversation, oldest first.
  Stream<List<AgentMessage>> watchMessages(String userId, String chatId) {
    return _messages(userId, chatId)
        .orderBy('createdAtMs')
        .limit(300)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => AgentMessage.fromMap(d.id, d.data()))
              .toList(growable: false),
        );
  }

  /// History list, most recently used first.
  Stream<List<AgentChatSummary>> watchChats(String userId) {
    return _chats(userId)
        .orderBy('updatedAtMs', descending: true)
        .limit(60)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => AgentChatSummary.fromMap(d.id, d.data()))
              .toList(growable: false),
        );
  }

  // -------------------------------------------------------------------------
  // Calls
  // -------------------------------------------------------------------------

  /// Sends one user message. [chatId] null starts a new conversation.
  Future<AgentTurnResponse> send({
    required String text,
    String? chatId,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
    await _ensureAuth();
    final callable = _functions.httpsCallable(
      'aivyAgent',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 120)),
    );
    final googleToken = await FirebaseSession.googleAccessTokenOrNull();
    final res = await callable.call<Map<String, dynamic>>(<String, dynamic>{
      'text': trimmed,
      if (chatId != null && chatId.isNotEmpty) 'chatId': chatId,
      'timezone': await _timezone(),
      'nowIso': _nowIso(),
      if (googleToken != null) 'googleAccessToken': googleToken,
    });
    return AgentTurnResponse.fromMap(Map<String, dynamic>.from(res.data));
  }

  /// Confirms a card — this is the point at which anything is written.
  Future<AgentCommitResult> commit({
    required String draftId,
    String? chatId,
  }) {
    return _draftAction(draftId: draftId, chatId: chatId);
  }

  /// Dismisses a card. Deliberately not routed through the model — throwing a
  /// full conversational turn at "rehne do" would cost a round trip to do
  /// nothing.
  Future<AgentCommitResult> cancelDraft({required String draftId}) {
    return _draftAction(draftId: draftId, action: 'cancel');
  }

  Future<AgentCommitResult> _draftAction({
    required String draftId,
    String? chatId,
    String? action,
  }) async {
    await _ensureAuth();
    // Cancelling touches nothing outside Firestore, so it needs no Google
    // token; confirming might send a mail or book a calendar slot, so it does.
    final googleToken =
        action == 'cancel' ? null : await FirebaseSession.googleAccessTokenOrNull();
    final callable = _functions.httpsCallable('aivyAgentCommit');
    final res = await callable.call<Map<String, dynamic>>(<String, dynamic>{
      'draftId': draftId,
      if (chatId != null && chatId.isNotEmpty) 'chatId': chatId,
      if (action != null) 'action': action,
      if (googleToken != null) 'googleAccessToken': googleToken,
    });
    return AgentCommitResult.fromMap(Map<String, dynamic>.from(res.data));
  }

  Future<String?> newChat() async {
    await _ensureAuth();
    final res = await _chatsCallable(<String, dynamic>{'action': 'new'});
    final chat = res['chat'];
    if (chat is Map) {
      return (chat['id'] as String?)?.trim();
    }
    return null;
  }

  Future<void> renameChat(String chatId, String title) async {
    await _ensureAuth();
    await _chatsCallable(<String, dynamic>{
      'action': 'rename',
      'chatId': chatId,
      'title': title,
    });
  }

  Future<void> deleteChat(String chatId) async {
    await _ensureAuth();
    await _chatsCallable(<String, dynamic>{
      'action': 'delete',
      'chatId': chatId,
    });
  }

  Future<Map<String, dynamic>> _chatsCallable(Map<String, dynamic> payload) async {
    final callable = _functions.httpsCallable('aivyAgentChats');
    final res = await callable.call<Map<String, dynamic>>(payload);
    return Map<String, dynamic>.from(res.data);
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  Future<void> _ensureAuth() async {
    final user = _auth.currentUser;
    if (user == null) {
      await FirebaseSession.ensureAuthenticatedUser(forceTokenRefresh: true);
      return;
    }
    await user.getIdToken();
  }

  Future<String> _timezone() async {
    final cached = _cachedTimezone;
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    try {
      final zone = await FlutterTimezone.getLocalTimezone();
      _cachedTimezone = zone;
      return zone;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[AivyAgent] timezone lookup failed: $error');
      }
      _cachedTimezone = 'Asia/Kolkata';
      return _cachedTimezone!;
    }
  }

  /// Local ISO-8601 including the numeric offset — the backend needs the offset
  /// to place "kal 11 baje" on the right instant.
  String _nowIso() {
    final local = DateTime.now().toLocal();
    final base = local.toIso8601String();
    final offset = local.timeZoneOffset;
    if (offset == Duration.zero) {
      return '${base}Z';
    }
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    final hours = abs.inHours.toString().padLeft(2, '0');
    final minutes = (abs.inMinutes % 60).toString().padLeft(2, '0');
    return '$base$sign$hours:$minutes';
  }
}
