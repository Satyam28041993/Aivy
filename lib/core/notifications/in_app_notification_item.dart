import 'package:cloud_firestore/cloud_firestore.dart';

class InAppNotificationItem {
  const InAppNotificationItem({
    required this.id,
    required this.title,
    required this.message,
    required this.type,
    required this.read,
    required this.createdAtMs,
    this.clientName,
    this.amount,
  });

  final String id;
  final String title;
  final String message;
  final String type;
  final bool read;
  final int createdAtMs;
  final String? clientName;
  final double? amount;

  factory InAppNotificationItem.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    return InAppNotificationItem(
      id: doc.id,
      title: (data['title'] as String? ?? '').trim(),
      message: (data['message'] as String? ?? '').trim(),
      type: (data['type'] as String? ?? 'payment_due').trim(),
      read: data['read'] as bool? ?? false,
      createdAtMs: (data['createdAtMs'] as num?)?.toInt() ?? 0,
      clientName: data['clientName'] as String?,
      amount: (data['amount'] as num?)?.toDouble(),
    );
  }
}
