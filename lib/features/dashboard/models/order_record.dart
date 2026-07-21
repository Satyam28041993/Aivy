import 'package:cloud_firestore/cloud_firestore.dart';

/// Business order: `users/{userId}/orders`
/// Lifecycle: [status] `pending` → `dispatched` with [dispatchDate] set at mark time.
class OrderRecord {
  const OrderRecord({
    required this.id,
    required this.amount,
    required this.createdAtMs,
    required this.status,
    this.dispatchDateMs,
    this.dispatchedAtMs,
    this.clientName,
    this.processStage,
  });

  final String id;
  final double amount;
  final int createdAtMs;
  final String status;
  /// When the business marked the order as dispatched (canonical, server timestamp in Firestore).
  final int? dispatchDateMs;
  final int? dispatchedAtMs;
  final String? clientName;
  final String? processStage;

  static int _readCreatedMs(Map<String, dynamic> data) {
    final m = (data['createdAtMs'] as num?)?.toInt();
    if (m != null && m > 0) {
      return m;
    }
    final t = data['createdAt'];
    if (t is Timestamp) {
      return t.millisecondsSinceEpoch;
    }
    return 0;
  }

  static int? _readTimestampField(Map<String, dynamic> data, String key) {
    final v = data[key];
    if (v is Timestamp) {
      return v.millisecondsSinceEpoch;
    }
    if (v == null) {
      return null;
    }
    if (v is num && v > 0) {
      return v.toInt();
    }
    return null;
  }

  /// When the business marked the order (canonical [dispatchDate] or legacy [dispatchedAtMs]).
  int? get dispatchInstantMs {
    if (dispatchDateMs != null && dispatchDateMs! > 0) {
      return dispatchDateMs;
    }
    if (dispatchedAtMs != null && dispatchedAtMs! > 0) {
      return dispatchedAtMs;
    }
    return null;
  }

  factory OrderRecord.fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final raw = data['amount'];
    var amount = 0.0;
    if (raw is num) {
      amount = raw.toDouble();
    }
    var st = (data['status'] as String? ?? 'pending').trim().toLowerCase();
    if (st.isEmpty) {
      st = 'pending';
    }
    return OrderRecord(
      id: doc.id,
      amount: amount,
      createdAtMs: _readCreatedMs(data),
      status: st,
      dispatchDateMs: _readTimestampField(data, 'dispatchDate'),
      dispatchedAtMs: (data['dispatchedAtMs'] as num?)?.toInt(),
      clientName: (data['clientName'] as String? ?? data['client'] as String?),
      processStage: (data['processStage'] as String?)?.trim(),
    );
  }

  /// True when this order still needs to be shipped / marked.
  bool get isPending {
    if (status == 'dispatched') {
      return false;
    }
    if (status == 'cancelled' || status == 'canceled') {
      return false;
    }
    if (dispatchInstantMs != null) {
      return false;
    }
    if (status == 'pending' || status == 'created' || status.isEmpty) {
      return true;
    }
    return false;
  }

  bool get isDispatched {
    if (status == 'dispatched') {
      return true;
    }
    if (dispatchInstantMs != null) {
      return true;
    }
    return false;
  }
}

/// In-memory rollups (same window rules as cloud analytics).
class OrderDashMetrics {
  const OrderDashMetrics({
    required this.ordersToday,
    required this.ordersThisMonth,
    required this.pendingCount,
    required this.dispatchToday,
    required this.dispatchThisMonth,
  });

  final int ordersToday;
  final int ordersThisMonth;
  final int pendingCount;
  final int dispatchToday;
  final int dispatchThisMonth;

  static OrderDashMetrics compute(
    List<OrderRecord> orders, {
    required DateTime startOfToday,
    required DateTime startOfNextDay,
    required DateTime startOfMonth,
    required DateTime endOfMonthExclusive,
  }) {
    final t0 = startOfToday.millisecondsSinceEpoch;
    final t1 = startOfNextDay.millisecondsSinceEpoch;
    final m0 = startOfMonth.millisecondsSinceEpoch;
    final m1 = endOfMonthExclusive.millisecondsSinceEpoch;

    var oToday = 0;
    var oMonth = 0;
    var pending = 0;
    var dToday = 0;
    var dMonth = 0;
    for (final o in orders) {
      if (o.isPending) {
        pending += 1;
      }
      final c = o.createdAtMs;
      if (c >= t0 && c < t1) {
        oToday += 1;
      }
      if (c >= m0 && c < m1) {
        oMonth += 1;
      }
      if (o.status == 'dispatched' && o.dispatchInstantMs != null) {
        final dms = o.dispatchInstantMs!;
        if (dms >= t0 && dms < t1) {
          dToday += 1;
        }
        if (dms >= m0 && dms < m1) {
          dMonth += 1;
        }
      }
    }
    return OrderDashMetrics(
      ordersToday: oToday,
      ordersThisMonth: oMonth,
      pendingCount: pending,
      dispatchToday: dToday,
      dispatchThisMonth: dMonth,
    );
  }
}
