import 'package:cloud_firestore/cloud_firestore.dart';

/// One chat thread under `users/{userId}/chats/{chatId}`.
class ChatSession {
  const ChatSession({
    required this.id,
    required this.title,
    required this.updatedAtMs,
    required this.createdAtMs,
  });

  final String id;
  final String title;
  final int updatedAtMs;
  final int createdAtMs;

  factory ChatSession.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final rawTitle = (data['title'] as String?)?.trim() ?? '';
    final created = (data['createdAtMs'] as num?)?.toInt() ?? 0;
    final updated = (data['updatedAtMs'] as num?)?.toInt() ?? created;
    return ChatSession(
      id: doc.id,
      title: rawTitle.isEmpty ? 'New chat' : rawTitle,
      updatedAtMs: updated,
      createdAtMs: created,
    );
  }
}
