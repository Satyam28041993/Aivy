import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import 'firebase_session.dart';

/// The three server calls the app still makes outside the agent.
///
/// This was `AivyProcessService`, and it was named after `aivyProcess` — the
/// chat pipeline that the agent replaced. Everything to do with that pipeline
/// has gone; what is left is the dashboard's stats rebuild, its figures, and
/// marking a notification read. Keeping the old name on a class that no longer
/// calls `aivyProcess` is how a repo stops telling the truth about itself.
class AivyCallables {
  AivyCallables({FirebaseFunctions? functions, FirebaseAuth? auth})
      : _functions = functions ?? FirebaseSession.functions,
        _auth = auth ?? FirebaseSession.auth;

  final FirebaseFunctions _functions;
  final FirebaseAuth _auth;

  String? _cachedTimezone;

  /// Rebuilds `client_stats` and `meta/client_insights` on the server.
  Future<void> syncClientStats() async {
    await _ensureAuthReady();
    final timezone = await _resolveTimezone();
    final callable = _functions.httpsCallable('syncClientStats');
    try {
      await callable.call(<String, dynamic>{'timezone': timezone});
    } on FirebaseFunctionsException catch (e) {
      // A stale stat is worth far less than a screen that fails to open.
      if (kDebugMode) {
        debugPrint('[Aivy] syncClientStats failed: ${e.message}');
      }
    }
  }

  /// Server dashboard: due counts, follow-ups, total pending amount.
  Future<Map<String, dynamic>> fetchDashboardStats() async {
    await _ensureAuthReady();
    final timezone = await _resolveTimezone();
    final callable = _functions.httpsCallable('getDashboardStats');
    final response = await callable.call(<String, dynamic>{
      'timeZone': timezone,
    });
    final data = response.data;
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  /// Marks one in-app notification read, or [markAllRead] for all of them.
  Future<int?> markNotificationRead({
    String? notificationId,
    bool markAllRead = false,
  }) async {
    await _ensureAuthReady();
    final callable = _functions.httpsCallable('markNotificationRead');
    final response = await callable.call(<String, dynamic>{
      if (notificationId != null) 'notificationId': notificationId,
      'markAllRead': markAllRead,
    });
    final data = response.data;
    final count = data is Map ? data['count'] : null;
    return count is int ? count : null;
  }

  Future<void> _ensureAuthReady() async {
    final user = _auth.currentUser;
    if (user == null) {
      await FirebaseSession.ensureAuthenticatedUser(forceTokenRefresh: true);
      return;
    }
    final idToken = await user.getIdToken(true);
    if (idToken == null || idToken.trim().isEmpty) {
      throw StateError('Unable to get auth token for callable request.');
    }
  }

  Future<String> _resolveTimezone() async {
    final cached = _cachedTimezone;
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    try {
      final zone = await FlutterTimezone.getLocalTimezone();
      _cachedTimezone = zone;
      return zone;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[Aivy] Failed to resolve local timezone: $error');
      }
      _cachedTimezone = 'UTC';
      return 'UTC';
    }
  }

  void dispose() {}
}
