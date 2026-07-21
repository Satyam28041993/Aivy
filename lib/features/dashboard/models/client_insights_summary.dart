import 'package:cloud_firestore/cloud_firestore.dart';

/// Cached precomputed snapshot at `users/{uid}/meta/client_insights`.
class ClientInsightsSummary {
  const ClientInsightsSummary({
    required this.totalDue,
    required this.overdueAmount,
    required this.todayDueCount,
    required this.riskyClientsCount,
    required this.oneLiner,
    this.asOfMs,
    this.fullText,
  });

  final double totalDue;
  final double overdueAmount;
  final int todayDueCount;
  final int riskyClientsCount;
  final String oneLiner;
  final int? asOfMs;
  final String? fullText;

  factory ClientInsightsSummary.fromMap(Map<String, dynamic> data) {
    return ClientInsightsSummary(
      totalDue: (data['totalDue'] as num?)?.toDouble() ?? 0,
      overdueAmount: (data['overdueAmount'] as num?)?.toDouble() ?? 0,
      todayDueCount: (data['todayDueCount'] as num?)?.toInt() ?? 0,
      riskyClientsCount: (data['riskyClientsCount'] as num?)?.toInt() ?? 0,
      oneLiner: data['oneLiner'] as String? ?? '',
      asOfMs: (data['asOfMs'] as num?)?.toInt(),
      fullText: data['fullText'] as String?,
    );
  }

  factory ClientInsightsSummary.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    return ClientInsightsSummary.fromMap(doc.data() ?? const <String, dynamic>{});
  }
}
