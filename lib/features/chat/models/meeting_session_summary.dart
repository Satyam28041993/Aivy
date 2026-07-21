import 'package:cloud_firestore/cloud_firestore.dart';

/// One saved meeting under `users/{uid}/sessions/{id}`.
class MeetingSessionSummary {
  const MeetingSessionSummary({
    required this.id,
    required this.entryId,
    required this.chatId,
    required this.durationMs,
    required this.transcriptPreview,
    required this.summary,
    required this.createdAtMs,
  });

  final String id;
  final String entryId;
  final String chatId;
  final int durationMs;
  final String transcriptPreview;
  final String summary;
  final int createdAtMs;

  factory MeetingSessionSummary.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data();
    return MeetingSessionSummary(
      id: doc.id,
      entryId: (d['entryId'] as String? ?? '').trim(),
      chatId: (d['chatId'] as String? ?? '').trim(),
      durationMs: (d['durationMs'] as num?)?.toInt() ?? 0,
      transcriptPreview: (d['transcriptPreview'] as String? ?? '').trim(),
      summary: (d['summary'] as String? ?? '').trim(),
      createdAtMs: (d['createdAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}
