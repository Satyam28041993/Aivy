import 'package:cloud_firestore/cloud_firestore.dart';

/// Denormalized memory slice under `users/{uid}/memory/{entryId}`.
class MemoryEntrySummary {
  const MemoryEntrySummary({
    required this.entryId,
    required this.chatId,
    required this.memoryCategory,
    required this.summary,
    required this.intent,
    required this.createdAtMs,
  });

  final String entryId;
  final String chatId;
  final String memoryCategory;
  final String summary;
  final String intent;
  final int createdAtMs;

  factory MemoryEntrySummary.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data();
    return MemoryEntrySummary(
      entryId: doc.id,
      chatId: (d['chatId'] as String? ?? '').trim(),
      memoryCategory: (d['memoryCategory'] as String? ?? '').trim(),
      summary: (d['summary'] as String? ?? '').trim(),
      intent: (d['intent'] as String? ?? '').trim(),
      createdAtMs: (d['createdAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}
