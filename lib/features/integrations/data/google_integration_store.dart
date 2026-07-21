import 'package:cloud_firestore/cloud_firestore.dart';

/// Optional prefs for Google Sheets etc. under `users/{uid}/meta/google_prefs`.
class GoogleIntegrationStore {
  GoogleIntegrationStore({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _db.collection('users').doc(uid).collection('meta').doc('google_prefs');

  Future<String?> getDefaultSpreadsheetId(String uid) async {
    final s = await _doc(uid).get();
    final v = '${s.data()?['defaultSpreadsheetId'] ?? ''}'.trim();
    return v.isEmpty ? null : v;
  }

  Future<void> setDefaultSpreadsheetId(String uid, String spreadsheetId) async {
    final id = spreadsheetId.trim();
    if (id.isEmpty) {
      await _doc(uid).set(
        <String, dynamic>{
          'defaultSpreadsheetId': FieldValue.delete(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      return;
    }
    await _doc(uid).set(
      <String, dynamic>{
        'defaultSpreadsheetId': id,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }
}
