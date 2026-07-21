import 'payment_record.dart';

/// All open dues for one client plus total (for Reports).
class ClientPendingDuesSummary {
  const ClientPendingDuesSummary({
    required this.clientId,
    required this.clientName,
    required this.totalPending,
    required this.dues,
  });

  final String clientId;
  final String clientName;
  final double totalPending;
  final List<PaymentRecord> dues;
}
