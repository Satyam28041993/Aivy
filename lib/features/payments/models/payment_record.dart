import '../utils/payment_settlement_utils.dart';

import '../../structured_actions/models/structured_action.dart';
import '../../structured_actions/utils/name_normalize.dart';

/// Row in `users/{uid}/payments` — either a **due** or a **receipt** (`payment_received`).
class PaymentRecord {
  const PaymentRecord({
    required this.id,
    this.type = 'payment',
    this.subType = 'payment_due',
    required this.clientId,
    required this.clientName,
    this.clientNameLower = '',
    this.amount,
    this.status = 'pending',
    this.dueDateMs,
    this.invoiceLabel,
    this.linkedPaymentId,
    this.note,
    this.createdAtMs,
    this.paymentVersion,
    this.originalAmount,
    this.paidAmount,
    this.remainingAmount,
    this.receiptCount,
    this.lastReceivedAtMs,
    this.lastReceiptId,
    this.voided = false,
  });

  final String id;
  final String type;
  final String subType;
  final String clientId;
  final String clientName;
  final String clientNameLower;
  final double? amount;
  final String status;
  final int? dueDateMs;
  final String? invoiceLabel;
  final String? linkedPaymentId;
  final String? note;
  final int? createdAtMs;

  /// v2 settlement fields (optional on legacy docs).
  final int? paymentVersion;
  final double? originalAmount;
  final double? paidAmount;
  final double? remainingAmount;
  final int? receiptCount;
  final int? lastReceivedAtMs;
  final String? lastReceiptId;

  /// Receipt rows only — soft void for undo.
  final bool voided;

  bool get isPendingDue =>
      status.toLowerCase() == 'pending' ||
      status.toLowerCase() == 'overdue' ||
      status.toLowerCase() == 'partial_pending';

  /// True when this document is a **due** row (not a receipt log).
  bool get isPaymentDueDocument {
    final tyRaw = type.trim().toLowerCase();
    final ty = tyRaw.isEmpty ? 'payment' : tyRaw;
    final stpRaw = subType.trim().toLowerCase();
    final stp = stpRaw.isEmpty ? 'payment_due' : stpRaw;
    if (stp == 'payment_received') {
      return false;
    }
    if (ty == 'payment_due') {
      return true;
    }
    if (ty == 'payment' && (stp == 'payment_due' || stp == 'payment')) {
      return true;
    }
    return false;
  }

  /// Open amount owed (excludes receipts; includes legacy `type: payment` dues).
  bool get isOpenPaymentDue {
    if (!isPaymentDueDocument) {
      return false;
    }
    final st = status.toLowerCase();
    if (!PaymentSettlementUtils.isOpenDueStatus(st)) {
      return false;
    }
    return true;
  }

  /// Original due face value (backward compatible: [amount] when v2 missing).
  double get effectiveOriginal {
    if (originalAmount != null && originalAmount! > 0) {
      return originalAmount!;
    }
    return (amount ?? 0) > 0 ? amount! : 0;
  }

  /// Paid portion on the due row (0 when missing).
  double get effectivePaid {
    final p = paidAmount;
    if (p != null && p >= 0) {
      return p;
    }
    return 0;
  }

  /// Remaining collectible — **use for open-due totals**, not raw [amount].
  double get effectiveRemaining {
    final r = remainingAmount;
    if (r != null && r >= 0) {
      return r;
    }
    return effectiveOriginal - effectivePaid;
  }

  /// Same due row with client fields resolved for grouping (e.g. missing [clientId] on doc).
  PaymentRecord withClientResolution({
    required String newClientId,
    required String newClientName,
  }) {
    final cn = newClientName.trim();
    final cid = newClientId.trim();
    return PaymentRecord(
      id: id,
      type: type,
      subType: subType,
      clientId: cid,
      clientName: cn,
      clientNameLower: cn.isNotEmpty ? normalizeName(cn) : clientNameLower,
      amount: amount,
      status: status,
      dueDateMs: dueDateMs,
      invoiceLabel: invoiceLabel,
      linkedPaymentId: linkedPaymentId,
      note: note,
      createdAtMs: createdAtMs,
      paymentVersion: paymentVersion,
      originalAmount: originalAmount,
      paidAmount: paidAmount,
      remainingAmount: remainingAmount,
      receiptCount: receiptCount,
      lastReceivedAtMs: lastReceivedAtMs,
      lastReceiptId: lastReceiptId,
      voided: voided,
    );
  }

  /// Synthetic due row from CRM [StructuredAction] for grouping / picker UX.
  static PaymentRecord fromOpenStructuredDue(
    StructuredAction a, {
    required String resolvedClientId,
    required String resolvedClientName,
  }) {
    final sid = (a.id ?? '').trim();
    final cid = resolvedClientId.trim();
    final cn = resolvedClientName.trim();
    final nl = cn.isNotEmpty ? normalizeName(cn) : '';
    return PaymentRecord(
      id: sid.isNotEmpty ? sid : 'legacy_${cid}_${a.createdAt.millisecondsSinceEpoch}',
      type: 'payment',
      subType: a.subType.trim().isEmpty ? 'payment_due' : a.subType.trim(),
      clientId: cid,
      clientName: cn,
      clientNameLower: nl,
      amount: a.amount,
      status: a.status.trim().isEmpty ? 'pending' : a.status.trim(),
      dueDateMs: a.date?.millisecondsSinceEpoch,
      note: a.note,
      createdAtMs: a.createdAt.millisecondsSinceEpoch,
    );
  }

  static PaymentRecord fromDoc(String id, Map<String, dynamic> d) {
    final voidRaw = d['voided'];
    final voided = voidRaw == true;
    return PaymentRecord(
      id: id,
      type: (d['type'] as String? ?? 'payment').trim(),
      subType: (d['subType'] as String? ?? 'payment_due').trim(),
      clientId: (d['clientId'] as String? ?? '').trim(),
      clientName: (d['clientName'] as String? ?? d['client'] as String? ?? '')
          .trim(),
      clientNameLower: (d['clientNameLower'] as String? ?? '').trim(),
      amount: (d['amount'] as num?)?.toDouble(),
      status: (d['status'] as String? ?? 'pending').trim(),
      dueDateMs: (d['dueDateMs'] as num?)?.toInt(),
      invoiceLabel: (d['invoiceLabel'] as String? ?? '').trim().isEmpty
          ? null
          : d['invoiceLabel'] as String?,
      linkedPaymentId: (d['linkedPaymentId'] as String? ?? '').trim().isEmpty
          ? null
          : d['linkedPaymentId'] as String?,
      note: (d['note'] as String? ?? '').trim().isEmpty
          ? null
          : d['note'] as String?,
      createdAtMs: (d['createdAtMs'] as num?)?.toInt(),
      paymentVersion: (d['paymentVersion'] as num?)?.toInt(),
      originalAmount: (d['originalAmount'] as num?)?.toDouble(),
      paidAmount: (d['paidAmount'] as num?)?.toDouble(),
      remainingAmount: (d['remainingAmount'] as num?)?.toDouble(),
      receiptCount: (d['receiptCount'] as num?)?.toInt(),
      lastReceivedAtMs: (d['lastReceivedAtMs'] as num?)?.toInt(),
      lastReceiptId: (d['lastReceiptId'] as String? ?? '').trim().isEmpty
          ? null
          : d['lastReceiptId'] as String?,
      voided: voided,
    );
  }

  /// Sort: oldest due first, then highest remaining.
  static int compareOpenDuesForReceiptPicker(PaymentRecord a, PaymentRecord b) {
    final da = a.dueDateMs ?? 0;
    final db = b.dueDateMs ?? 0;
    final c = da.compareTo(db);
    if (c != 0) {
      return c;
    }
    return b.effectiveRemaining.compareTo(a.effectiveRemaining);
  }
}
