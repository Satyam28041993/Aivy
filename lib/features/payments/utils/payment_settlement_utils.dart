/// Shared Firestore read helpers for payment dues and receipts.
/// Invariant for **open** dues: displayed outstanding uses [effectiveRemainingFromDueMap],
/// never raw `amount`, when status is an open due state.
class PaymentSettlementUtils {
  PaymentSettlementUtils._();

  static const Set<String> openDueStatuses = {
    'pending',
    'overdue',
    'partial_pending',
    '',
    'open',
    'active',
  };

  static bool isOpenDueStatus(String? status) {
    final s = (status ?? '').trim().toLowerCase();
    return openDueStatuses.contains(s);
  }

  static bool isVoidedReceiptMap(Map<String, dynamic> d) {
    final v = d['voided'];
    return v == true;
  }

  static double coercePositiveAmount(Object? raw) {
    if (raw is num) {
      return raw.toDouble().clamp(0.0, double.infinity);
    }
    return 0.0;
  }

  /// Original due face value (legacy: `amount` only).
  static double effectiveOriginalFromDueMap(Map<String, dynamic> d) {
    final o = (d['originalAmount'] as num?)?.toDouble();
    if (o != null && o > 0) {
      return o;
    }
    final a = (d['amount'] as num?)?.toDouble();
    return a != null && a > 0 ? a : 0.0;
  }

  static double effectivePaidFromDueMap(Map<String, dynamic> d) {
    final p = (d['paidAmount'] as num?)?.toDouble();
    if (p != null && p >= 0) {
      return p;
    }
    return 0.0;
  }

  /// Remaining collectible on a **due** row; falls back to `amount` when v2 missing.
  static double effectiveRemainingFromDueMap(Map<String, dynamic> d) {
    final r = (d['remainingAmount'] as num?)?.toDouble();
    if (r != null && r >= 0) {
      return r;
    }
    return effectiveOriginalFromDueMap(d) - effectivePaidFromDueMap(d);
  }

  static bool isCalendarDueBeforeToday(int dueMs) {
    final due = DateTime.fromMillisecondsSinceEpoch(dueMs);
    final now = DateTime.now();
    return DateTime(due.year, due.month, due.day)
        .isBefore(DateTime(now.year, now.month, now.day));
  }

  /// When [paidAmount] is zero, return pending vs overdue from calendar due date.
  static String statusForFullyUnpaidDue({
    required int? dueDateMs,
    required int nowMs,
  }) {
    final dm = dueDateMs ?? 0;
    if (dm <= 0) {
      return 'pending';
    }
    return isCalendarDueBeforeToday(dm) ? 'overdue' : 'pending';
  }

}
