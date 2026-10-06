/// One day's travel claim, as `functions/src/agent/expenseStore.ts` writes it:
/// start → each visit of the day → back, priced per km.
class TravelExpense {
  const TravelExpense({
    required this.id,
    required this.dateMs,
    required this.dateLabel,
    required this.startPoint,
    required this.vehicle,
    required this.ratePerKm,
    required this.legs,
    required this.totalKm,
    required this.totalAmount,
    required this.inSheet,
  });

  /// yyyy-MM-dd.
  final String id;
  final int dateMs;
  final String dateLabel;
  final String startPoint;
  final String vehicle;
  final double ratePerKm;
  final List<ExpenseLeg> legs;
  final double totalKm;
  final double totalAmount;

  /// Copied to the expense Google Sheet yet.
  final bool inSheet;

  DateTime get date => DateTime.fromMillisecondsSinceEpoch(dateMs);

  static double _d(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? 0;
  }

  static String _s(Object? v) => v == null ? '' : v.toString().trim();

  factory TravelExpense.fromMap(String id, Map<String, dynamic> d) {
    final rawLegs = d['legs'];
    final legs = <ExpenseLeg>[
      if (rawLegs is List)
        for (final l in rawLegs)
          if (l is Map)
            ExpenseLeg(
              from: _s(l['from']),
              to: _s(l['to']),
              purpose: _s(l['purpose']),
              km: _d(l['km']),
              amount: _d(l['amount']),
            ),
    ];
    final row = d['sheetRow'];
    return TravelExpense(
      id: id,
      dateMs: _d(d['dateMs']).toInt(),
      dateLabel: _s(d['dateLabel']),
      startPoint: _s(d['startPoint']),
      vehicle: _s(d['vehicle']),
      ratePerKm: _d(d['ratePerKm']),
      legs: legs,
      totalKm: _d(d['totalKm']),
      totalAmount: _d(d['totalAmount']),
      inSheet: row is num && row > 0,
    );
  }
}

class ExpenseLeg {
  const ExpenseLeg({
    required this.from,
    required this.to,
    required this.purpose,
    required this.km,
    required this.amount,
  });

  final String from;
  final String to;
  final String purpose;
  final double km;
  final double amount;
}

/// "12.5" not "12.50", "40" not "40.0".
String trimNum(double n) {
  final s = n.toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}
