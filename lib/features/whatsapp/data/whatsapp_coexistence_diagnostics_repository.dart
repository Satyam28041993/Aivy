import 'package:cloud_firestore/cloud_firestore.dart';

class WhatsappCoexistenceDiagnosticsSnapshot {
  const WhatsappCoexistenceDiagnosticsSnapshot({
    this.summary = const {},
    this.lastHistory,
    this.lastSmbSync,
    this.lastEcho,
  });

  final Map<String, dynamic> summary;
  final Map<String, dynamic>? lastHistory;
  final Map<String, dynamic>? lastSmbSync;
  final Map<String, dynamic>? lastEcho;

  String get lastProcessingStatus =>
      '${summary['lastProcessingStatus'] ?? ''}'.trim();

  List<String> get parseErrors {
    final raw = summary['lastParseErrors'];
    if (raw is! List) {
      return const [];
    }
    return raw.map((e) => '$e').toList(growable: false);
  }
}

/// Read-only diagnostics for coexistence webhook observability (admin/debug).
class WhatsappCoexistenceDiagnosticsRepository {
  WhatsappCoexistenceDiagnosticsRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Stream<WhatsappCoexistenceDiagnosticsSnapshot> watchDiagnostics() async* {
    await for (final summarySnap
        in _firestore.doc('whatsapp_coexistence_diagnostics/summary').snapshots()) {
      final historySnap = await _firestore
          .collection('whatsapp_coexistence_history')
          .orderBy('lastSeenAtMs', descending: true)
          .limit(1)
          .get();
      final smbSnap = await _firestore
          .collection('whatsapp_coexistence_app_state_sync')
          .orderBy('lastSeenAtMs', descending: true)
          .limit(1)
          .get();
      final echoSnap = await _firestore
          .collection('whatsapp_coexistence_message_echoes')
          .orderBy('lastSeenAtMs', descending: true)
          .limit(1)
          .get();

      yield WhatsappCoexistenceDiagnosticsSnapshot(
        summary: summarySnap.data() ?? const {},
        lastHistory: historySnap.docs.isEmpty
            ? null
            : historySnap.docs.first.data(),
        lastSmbSync: smbSnap.docs.isEmpty ? null : smbSnap.docs.first.data(),
        lastEcho: echoSnap.docs.isEmpty ? null : echoSnap.docs.first.data(),
      );
    }
  }
}
