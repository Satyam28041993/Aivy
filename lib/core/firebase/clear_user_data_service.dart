import 'package:cloud_functions/cloud_functions.dart';

import 'firebase_session.dart';

/// Server-side delete of the signed-in user's Firestore subtree via
/// the [clearUserData] callable (Admin SDK: recursive delete or date filter).
class ClearUserDataService {
  ClearUserDataService({FirebaseFunctions? functions})
    : _functions = functions ?? FirebaseSession.functions;

  final FirebaseFunctions _functions;

  static const String wipeConfirmPhrase = 'DELETE ALL MY DATA';

  /// Removes **everything** under `users/{uid}` in Firestore (same as CLI wipe).
  Future<void> wipeAll() async {
    final callable = _functions.httpsCallable('clearUserData');
    await callable.call<void>(<String, dynamic>{
      'mode': 'wipe',
      'confirmPhrase': wipeConfirmPhrase,
    });
  }

  /// Removes every business record but keeps what Aivy has learned about you.
  ///
  /// Different from [wipeAll] in two ways that matter: `memory/` and the Google
  /// settings survive, and WhatsApp history — which lives outside the user
  /// subtree — is included.
  Future<Map<String, dynamic>?> freshStart({bool includeWhatsApp = true}) async {
    final callable = _functions.httpsCallable(
      'aivyResetData',
      options: HttpsCallableOptions(timeout: const Duration(minutes: 9)),
    );
    final result = await callable.call<dynamic>(<String, dynamic>{
      'confirmPhrase': wipeConfirmPhrase,
      'includeWhatsApp': includeWhatsApp,
    });
    return _asMap(result.data);
  }

  /// Delete documents whose timestamps fall **strictly before** [before] (start of that local day).
  Future<Map<String, dynamic>?> deleteBefore(DateTime before) async {
    final start = DateTime(before.year, before.month, before.day);
    final callable = _functions.httpsCallable('clearUserData');
    final result = await callable.call<dynamic>(<String, dynamic>{
      'mode': 'dateFilter',
      'op': 'before',
      'beforeMs': start.millisecondsSinceEpoch,
    });
    return _asMap(result.data);
  }

  /// Delete documents with timestamp **after** end of [after] day (local).
  Future<Map<String, dynamic>?> deleteAfter(DateTime after) async {
    final d = DateTime(after.year, after.month, after.day, 23, 59, 59, 999);
    final callable = _functions.httpsCallable('clearUserData');
    final result = await callable.call<dynamic>(<String, dynamic>{
      'mode': 'dateFilter',
      'op': 'after',
      'afterMs': d.millisecondsSinceEpoch,
    });
    return _asMap(result.data);
  }

  /// Inclusive range: from start of [from] through end of [to] (local days).
  Future<Map<String, dynamic>?> deleteBetween(
    DateTime from,
    DateTime to,
  ) async {
    final a = DateTime(from.year, from.month, from.day);
    final b = DateTime(to.year, to.month, to.day, 23, 59, 59, 999);
    if (b.isBefore(a)) {
      throw ArgumentError('End date must be on or after start date');
    }
    final callable = _functions.httpsCallable('clearUserData');
    final result = await callable.call<dynamic>(<String, dynamic>{
      'mode': 'dateFilter',
      'op': 'between',
      'startMs': a.millisecondsSinceEpoch,
      'endMs': b.millisecondsSinceEpoch,
    });
    return _asMap(result.data);
  }

  Map<String, dynamic>? _asMap(Object? data) {
    if (data is Map) {
      return Map<String, dynamic>.from(
        data.map((k, v) => MapEntry(k.toString(), v)),
      );
    }
    return null;
  }
}
