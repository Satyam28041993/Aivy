import 'package:cloud_firestore/cloud_firestore.dart';

import '../../structured_actions/utils/name_normalize.dart';

/// Client profile in `users/{uid}/clients`.
class Client {
  const Client({
    required this.id,
    required this.name,
    required this.nameLower,
    this.outstandingBalance = 0,
  });

  final String id;
  final String name;
  final String nameLower;
  final double outstandingBalance;

  Map<String, dynamic> toFirestoreCreate() {
    return {
      'name': name.trim(),
      'nameLower': nameLower,
      'outstandingBalance': outstandingBalance,
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtMs': DateTime.now().millisecondsSinceEpoch,
    };
  }

  static Client fromDoc(String id, Map<String, dynamic> d) {
    final name = (d['name'] as String? ?? '').trim();
    final nlRaw = d['nameLower'] as String?;
    final nl = (nlRaw != null && nlRaw.isNotEmpty)
        ? nlRaw
        : (name.isNotEmpty ? normalizeName(name) : '');
    final bal = (d['outstandingBalance'] as num?)?.toDouble() ?? 0.0;
    return Client(
      id: id,
      name: name,
      nameLower: nl,
      outstandingBalance: bal,
    );
  }
}
