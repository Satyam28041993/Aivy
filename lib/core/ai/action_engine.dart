import 'package:cloud_firestore/cloud_firestore.dart';

import '../firebase/firebase_session.dart';
import 'intent_parser.dart';

class IntentResult {
  const IntentResult({required this.intent, required this.data});

  factory IntentResult.fromMap(Map<String, dynamic> raw) {
    final rawIntent = raw['intent'];
    final rawData = raw['data'];

    return IntentResult(
      intent: rawIntent is IntentType ? rawIntent : IntentType.unknown,
      data: rawData is Map<String, dynamic>
          ? rawData
          : Map<String, dynamic>.from(rawData as Map? ?? const {}),
    );
  }

  final IntentType intent;
  final Map<String, dynamic> data;
}

class ActionEngine {
  ActionEngine({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Future<String> handleIntent(IntentResult result) async {
    final user = await FirebaseSession.ensureAuthenticatedUser();
    final userRef = _firestore.collection('users').doc(user.uid);
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    switch (result.intent) {
      case IntentType.reminder:
        await userRef.collection('reminders').add({
          ...result.data,
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
          'createdAtMs': nowMs,
        });
        return 'Reminder saved successfully.';

      case IntentType.followUp:
        await userRef.collection('followups').add({
          ...result.data,
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
          'createdAtMs': nowMs,
        });
        return 'Follow-up saved successfully.';

      case IntentType.quotation:
        await userRef.collection('meta').doc('dashboard_stats').set({
          'quotationCount': FieldValue.increment(1),
          'lastQuotationInput': result.data['originalInput'],
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedAtMs': nowMs,
        }, SetOptions(merge: true));
        return 'Quotation stats updated successfully.';

      case IntentType.task:
        await userRef.collection('tasks').add({
          ...result.data,
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
          'createdAtMs': nowMs,
        });
        return 'Task saved successfully.';

      case IntentType.unknown:
        return 'No business action was triggered.';
    }
  }
}
