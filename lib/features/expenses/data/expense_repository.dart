import 'package:cloud_firestore/cloud_firestore.dart';

import '../../visits/models/visit_record.dart' show DsrSheet;
import '../models/travel_expense.dart';

/// Reads the travel claims from `users/{userId}/travelExpenses/*` and the
/// expense sheet's address from `users/{userId}/meta/expenseSheet`.
///
/// Read-only: a day's travel is recorded by telling Aivy where the day
/// started, which is the path that measures it and writes the sheet.
class ExpenseRepository {
  ExpenseRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> _user(String userId) =>
      _firestore.collection('users').doc(userId);

  /// Newest first. 400 days is more than a year of claims.
  Stream<List<TravelExpense>> watchExpenses(String userId, {int limit = 400}) {
    return _user(userId)
        .collection('travelExpenses')
        .orderBy('dateMs', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => TravelExpense.fromMap(d.id, d.data()))
            .where((e) => e.legs.isNotEmpty)
            .toList());
  }

  /// The expense sheet, once the first day has been copied to it. Same shape
  /// as the DSR sheet, so the same class carries its links.
  Stream<DsrSheet?> watchSheet(String userId) {
    return _user(userId).collection('meta').doc('expenseSheet').snapshots().map((snap) {
      final data = snap.data();
      final id = (data?['spreadsheetId'] ?? '').toString();
      if (id.isEmpty) {
        return null;
      }
      return DsrSheet(spreadsheetId: id, url: (data?['url'] ?? '').toString());
    });
  }
}
