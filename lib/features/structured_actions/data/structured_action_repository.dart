import 'package:cloud_firestore/cloud_firestore.dart';

import 'fuzzy_payment_query.dart';
import '../models/structured_action.dart';
import '../utils/name_normalize.dart';

class StructuredActionRepository {
  StructuredActionRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _col(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('structured_actions');
  }

  void _log(String label, Object? o) {
    // ignore: avoid_print
    print('AIVY_CTRL $label: $o');
  }

  static bool isOpenForPaymentQuery(StructuredAction a) {
    if (a.legacyMigrated) {
      return false;
    }
    final s = a.status.toLowerCase();
    if (a.type != 'payment' || s == 'completed' || s == 'reverted') {
      return false;
    }
    final stp = a.subType.trim().toLowerCase();
    if (stp == 'payment_received') {
      return false;
    }
    return true;
  }

  /// All open (pending, etc.) [payment] rows for the user.
  Future<List<StructuredAction>> getAllOpenPaymentActions(String userId) async {
    final snap = await _col(userId).where('type', isEqualTo: 'payment').get();
    final out = <StructuredAction>[];
    for (final d in snap.docs) {
      final a = StructuredAction.fromDoc(d.id, d.data());
      if (isOpenForPaymentQuery(a)) {
        out.add(a);
      }
    }
    return out;
  }

  /// Count of open payment rows (Phase 6 proactive hint).
  Future<int> countOpenPaymentActions(String userId) async {
    final all = await getAllOpenPaymentActions(userId);
    return all.length;
  }

  /// Sample distinct client [name]s (display) for proactive copy.
  Future<List<String>> sampleOpenPaymentClientNames(
    String userId, {
    int maxNames = 3,
  }) async {
    final all = await getAllOpenPaymentActions(userId);
    final seen = <String>{};
    final out = <String>[];
    for (final a in all) {
      final k = a.nameLower.isNotEmpty ? a.nameLower : normalizeName(a.name);
      if (k.isEmpty) {
        continue;
      }
      if (seen.add(k)) {
        final display = a.name.isNotEmpty ? a.name : k;
        out.add(display);
        if (out.length >= maxNames) {
          break;
        }
      }
    }
    return out;
  }

  Future<String> save(StructuredAction action, {required String userId}) async {
    final now = action.createdAt;
    final ref = _col(userId).doc();
    final data = action.toFirestore();
    data['createdAt'] = FieldValue.serverTimestamp();
    data['createdAtMs'] = now.millisecondsSinceEpoch;
    data['id'] = ref.id;
    if (!data.containsKey('status') || (data['status'] as String?)?.isEmpty == true) {
      data['status'] = 'pending';
    }
    await ref.set(data);
    return ref.id;
  }

  /// Phase 6: fuzzy (exact, alias, startsWith, contains). Multiple clients →
  /// [FuzzyPaymentQueryResult.needsNamePick].
  Future<FuzzyPaymentQueryResult> queryFuzzyOpenPaymentByName({
    required String userId,
    required String nameQuery,
  }) async {
    final n = normalizeName(nameQuery);
    _log('NORMALIZED_NAME', n);
    if (n.isEmpty) {
      return FuzzyPaymentQueryResult.empty();
    }
    final all = await getAllOpenPaymentActions(userId);
    final res = buildFuzzyPaymentResult(
      nameQuery: nameQuery,
      openPaymentDocs: all,
    );
    if (res.actions.isNotEmpty) {
      _log('SELECTION_FUZZY', {
        'query': n,
        'count': res.actions.length,
        'ids': res.actions.map((e) => e.id).toList(),
        'namePick': res.needsNamePick,
        'aliasLearn': res.hasAliasToLearn,
      });
    } else if (res.needsNamePick) {
      _log('SELECTION_FUZZY', {
        'query': n,
        'nameGroups': res.nameGroups?.length,
      });
    }
    return res;
  }

  Future<StructuredAction?> tryGetById(String userId, String id) async {
    final s = await _col(userId).doc(id).get();
    if (!s.exists || s.data() == null) {
      return null;
    }
    return StructuredAction.fromDoc(s.id, s.data()!);
  }

  /// Load rows by id (e.g. after name disambig).
  Future<List<StructuredAction>> getActionsByIds(
    String userId,
    List<String> ids,
  ) async {
    if (ids.isEmpty) {
      return const [];
    }
    final out = <StructuredAction>[];
    for (final id in ids) {
      final s = await _col(userId).doc(id).get();
      if (s.exists) {
        out.add(StructuredAction.fromDoc(s.id, s.data()!));
      }
    }
    return out;
  }

  Future<void> setStatus(String userId, String docId, String status) async {
    await _col(userId).doc(docId).update({
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Marks legacy structured payment due as migrated to [payments] (read-only thereafter).
  Future<void> markPaymentLegacyMigrated(
    String userId,
    String structuredActionId,
    String migratedToPaymentId,
  ) async {
    await _col(userId).doc(structuredActionId).set(
      {
        'legacyMigrated': true,
        'migratedToPaymentId': migratedToPaymentId.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
      },
      SetOptions(merge: true),
    );
  }

  /// Append [aliasToken] to every open [payment] row for [nameLower] (Phase 6).
  Future<void> appendAliasIfMissing(
    String userId,
    String nameLower, {
    required String aliasToken,
  }) async {
    final t = aliasToken.trim();
    if (t.isEmpty) {
      return;
    }
    final nTok = normalizeName(t);
    if (nTok.isEmpty || nTok == nameLower) {
      return;
    }
    final snap = await _col(userId).where('type', isEqualTo: 'payment').get();
    for (final d in snap.docs) {
      final a = StructuredAction.fromDoc(d.id, d.data());
      if (!isOpenForPaymentQuery(a)) {
        continue;
      }
      final k = a.nameLower.isNotEmpty ? a.nameLower : normalizeName(a.name);
      if (k != nameLower) {
        continue;
      }
      if (a.aliases.map(normalizeName).any((e) => e == nTok)) {
        continue;
      }
      await d.reference.update({
        'aliases': FieldValue.arrayUnion([nTok]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  /// Undo: remove a just-created document (legacy — prefer [revertAction] / status).
  Future<void> deleteAction(String userId, String docId) async {
    await _col(userId).doc(docId).delete();
  }

  /// Safe undo: keep history, mark reverted (Phase 6).
  Future<void> revertAction(String userId, String docId) async {
    await setStatus(userId, docId, 'reverted');
  }
}
