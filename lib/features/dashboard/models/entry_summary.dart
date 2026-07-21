import 'package:cloud_firestore/cloud_firestore.dart';

class EntrySummary {
  const EntrySummary({
    required this.id,
    required this.rawInput,
    required this.status,
    required this.contextType,
    required this.category,
    required this.memoryCategory,
    required this.clientName,
    required this.summary,
    required this.actionCount,
    required this.followUpCount,
    required this.reminderCount,
    required this.createdAtMs,
  });

  final String id;
  final String rawInput;
  final String status;
  final String contextType;

  /// `client`, `work`, `personal`, or `general`. Populated from the AI
  /// classification stored alongside the entry.
  final String category;

  /// `quotation`, `meeting`, `task`, `note`, or `general`.
  final String memoryCategory;

  /// Optional detected client or person name.
  final String clientName;
  final String summary;
  final int actionCount;
  final int followUpCount;
  final int reminderCount;
  final int createdAtMs;

  factory EntrySummary.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    return EntrySummary(
      id: doc.id,
      rawInput: data['rawInput'] as String? ?? '',
      status: data['status'] as String? ?? 'processing',
      contextType: data['contextType'] as String? ?? 'note',
      category: _normalizeCategory(data['category'] as String?),
      memoryCategory: _normalizeMemoryCategory(
        data['memoryCategory'] as String?,
      ),
      clientName: (data['clientName'] as String? ?? '').trim(),
      summary: data['summary'] as String? ?? '',
      actionCount: (data['actionItems'] as List?)?.length ?? 0,
      followUpCount: (data['followUpSuggestions'] as List?)?.length ?? 0,
      reminderCount: (data['reminderSuggestions'] as List?)?.length ?? 0,
      createdAtMs: (data['createdAtMs'] as num?)?.toInt() ?? 0,
    );
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
    const valid = {'quotation', 'meeting', 'task', 'note', 'general', 'goal'};
    if (valid.contains(lowered)) {
      return lowered;
    }
    return 'general';
  }
}
