import 'package:cloud_firestore/cloud_firestore.dart';

/// Cached result of the "Generate today's plan" call.
///
/// One document per calendar day lives at
/// `users/{uid}/daily_summary/{yyyy-MM-dd}`. The dashboard renders it as the
/// "Today's Focus" card.
class DailySummary {
  const DailySummary({
    required this.date,
    required this.summary,
    required this.bulletPoints,
    required this.assistantReply,
    required this.generatedAtMs,
    required this.todayTaskCount,
    required this.overdueTaskCount,
    required this.upcomingReminderCount,
  });

  /// Date key in `yyyy-MM-dd` format, matching the Firestore doc id.
  final String date;
  final String summary;
  final List<String> bulletPoints;
  final String assistantReply;
  final int generatedAtMs;
  final int todayTaskCount;
  final int overdueTaskCount;
  final int upcomingReminderCount;

  factory DailySummary.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return DailySummary(
      date: doc.id,
      summary: data['summary'] as String? ?? '',
      bulletPoints: _readStringList(data['bulletPoints']),
      assistantReply: data['assistantReply'] as String? ?? '',
      generatedAtMs: (data['generatedAtMs'] as num?)?.toInt() ?? 0,
      todayTaskCount: (data['todayTaskCount'] as num?)?.toInt() ?? 0,
      overdueTaskCount: (data['overdueTaskCount'] as num?)?.toInt() ?? 0,
      upcomingReminderCount:
          (data['upcomingReminderCount'] as num?)?.toInt() ?? 0,
    );
  }

  static List<String> _readStringList(Object? value) {
    if (value is! List) {
      return const <String>[];
    }
    return value
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  /// Builds the `yyyy-MM-dd` key for [date] in local time. Matches the doc
  /// id convention used by [ChatRepository.saveDailySummary].
  static String dateKey(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
