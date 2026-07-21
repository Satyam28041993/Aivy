import 'package:cloud_firestore/cloud_firestore.dart';

class QuotationRecord {
  const QuotationRecord({
    required this.id,
    required this.amount,
    required this.createdAtMs,
    required this.followUpDateMs,
    this.clientName,
  });

  final String id;
  final double amount;
  final int createdAtMs;
  final int followUpDateMs;
  final String? clientName;

  factory QuotationRecord.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final raw = data['amount'];
    double amount = 0;
    if (raw is num) {
      amount = raw.toDouble();
    }
    return QuotationRecord(
      id: doc.id,
      amount: amount,
      createdAtMs: (data['createdAtMs'] as num?)?.toInt() ?? 0,
      followUpDateMs: (data['followUpDateMs'] as num?)?.toInt() ?? 0,
      clientName: data['clientName'] as String?,
    );
  }
}
