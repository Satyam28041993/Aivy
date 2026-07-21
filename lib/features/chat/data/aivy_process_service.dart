import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../../../core/firebase/firebase_session.dart';
import '../models/aivy_ai_response.dart';

/// Client for the `aivyProcess` Callable Function.
///
/// Guarantees that every request carries the user's IANA timezone and
/// current local ISO string (with offset) so the backend can resolve
/// relative times like "today 8pm" correctly. Voice-only requests ship
/// the `audioUrl` alone — the backend transcribes with Gemini and uses
/// the transcript as the primary input.
class AivyProcessService {
  AivyProcessService({FirebaseFunctions? functions, FirebaseAuth? auth})
    : _functions = functions ?? FirebaseSession.functions,
      _auth = auth ?? FirebaseSession.auth;

  final FirebaseFunctions _functions;
  final FirebaseAuth _auth;

  String? _cachedTimezone;

  /// Processes a pure-text message. [inputText] must be non-empty.
  ///
  /// [clientIntent] is an optional client-side [detectIntent] label (e.g. `query`)
  /// used by the server to skip cross-intent rules.
  Future<AivyAiResponse> analyzeInput(
    String inputText, {
    String? clientIntent,
  }) async {
    final trimmed = inputText.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        inputText,
        'inputText',
        'inputText must not be empty when calling analyzeInput',
      );
    }

    final payload = await _buildBasePayload();
    payload['text'] = trimmed;
    final ci = clientIntent?.trim() ?? '';
    if (ci.isNotEmpty) {
      payload['clientIntent'] = ci;
    }
    return _callWithAuthRetry(payload);
  }

  /// Processes a voice message. [audioUrl] must be a Firebase Storage
  /// download URL under the caller's `users/{uid}/` path. [optionalText]
  /// can be used to attach a caption alongside the recording; when
  /// omitted the transcript alone becomes the AI input.
  Future<AivyAiResponse> analyzeVoice(
    String audioUrl, {
    String? optionalText,
    String? clientIntent,
  }) async {
    final trimmedUrl = audioUrl.trim();
    if (trimmedUrl.isEmpty) {
      throw ArgumentError.value(
        audioUrl,
        'audioUrl',
        'audioUrl must not be empty when calling analyzeVoice',
      );
    }

    final payload = await _buildBasePayload();
    payload['audioUrl'] = trimmedUrl;
    final captionTrimmed = optionalText?.trim() ?? '';
    if (captionTrimmed.isNotEmpty) {
      payload['text'] = captionTrimmed;
    }
    final ci = clientIntent?.trim() ?? '';
    if (ci.isNotEmpty) {
      payload['clientIntent'] = ci;
    }
    return _callWithAuthRetry(payload);
  }

  /// Legacy entry point: routes through the standard `aivyProcess` pipeline
  /// (PGPL jobs / payments / BI). The dedicated meeting mode was removed.
  Future<AivyAiResponse> analyzeMeetingVoice(String audioUrl) async {
    return analyzeVoice(audioUrl);
  }

  /// Legacy entry point: same as [analyzeInput] for typed or on-device STT text.
  Future<AivyAiResponse> analyzeMeetingTranscript(String transcript) async {
    return analyzeInput(transcript);
  }

  /// One-line professional English for WhatsApp preview (controlled chat flow).
  Future<String> translateForWhatsappPreview(String line) async {
    final t = line.trim();
    if (t.isEmpty) {
      return '';
    }
    await _ensureAuthReady(forceRefreshToken: false);
    final callable = _functions.httpsCallable('translateWaPreview');
    try {
      final res = await callable.call<Map<String, dynamic>>(<String, dynamic>{
        'text': t,
      });
      return '${res.data['english'] ?? ''}'.trim();
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        debugPrint('[Aivy] translateWaPreview: $e');
      }
      return '';
    }
  }

  Future<AivyAiResponse> _callWithAuthRetry(
    Map<String, dynamic> payload,
  ) async {
    try {
      return await _analyzeRequestInternal(payload: payload, isRetry: false);
    } on FirebaseFunctionsException catch (error) {
      if (_isUnauthenticated(error)) {
        if (kDebugMode) {
          debugPrint(
            '[Aivy] Received unauthenticated response, retrying once.',
          );
        }
        await _ensureAuthReady(forceRefreshToken: true);
        try {
          return await _analyzeRequestInternal(
            payload: payload,
            isRetry: true,
          );
        } on FirebaseFunctionsException catch (retryError) {
          throw Exception(_formatFunctionsError(retryError));
        }
      }
      throw Exception(_formatFunctionsError(error));
    }
  }

  Future<AivyAiResponse> _analyzeRequestInternal({
    required Map<String, dynamic> payload,
    required bool isRetry,
  }) async {
    final user = await _ensureAuthReady(forceRefreshToken: true);

    final callable = _functions.httpsCallable('aivyProcess');
    if (kDebugMode) {
      // Log the outgoing payload (redacting the full storage URL) so we
      // can see exactly what is hitting the backend when debugging the
      // voice and time-parsing flows.
      final redacted = <String, Object?>{
        for (final entry in payload.entries)
          entry.key: entry.key == 'audioUrl'
              ? _redactStorageUrl(entry.value?.toString() ?? '')
              : entry.value,
      };
      debugPrint(
        '[Aivy] aivyProcess request uid=${user.uid} retry=$isRetry payload=$redacted',
      );
    }

    final response = await callable.call(payload);

    final data = response.data;
    if (kDebugMode) {
      if (data is Map) {
        final keys = data.keys.map((key) => key.toString()).toList();
        final transcript = data['transcript'];
        final actionItems = data['actionItems'];
        final reminderCount = data['reminderSuggestions'] is List
            ? (data['reminderSuggestions'] as List).length
            : 0;
        debugPrint(
          '[Aivy] aivyProcess response uid=${user.uid} keys=$keys '
          'actionItems=${actionItems is List ? actionItems.length : 0} '
          'reminders=$reminderCount '
          'transcriptLen=${transcript is String ? transcript.length : 0}',
        );
      } else {
        debugPrint('[Aivy] aivyProcess response type=${data.runtimeType}');
      }
    }

    if (data is! Map) {
      throw StateError('aivyProcess returned an invalid response payload.');
    }

    return AivyAiResponse.fromJson(Map<String, dynamic>.from(data));
  }

  Future<Map<String, dynamic>> _buildBasePayload() async {
    final timezone = await _resolveTimezone();
    final nowIso = _nowIsoWithOffset();
    return <String, dynamic>{
      'timezone': timezone,
      'nowIso': nowIso,
    };
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

  /// Builds an ISO-8601 string representing "now" in the user's local
  /// timezone **including the numeric offset** (e.g. `+05:30`). Dart's
  /// built-in `toIso8601String()` on local DateTimes drops the offset,
  /// which the backend needs to interpret relative references correctly.
  String _nowIsoWithOffset() {
    final now = DateTime.now();
    final local = now.toLocal();
    final base = local.toIso8601String();
    final offset = local.timeZoneOffset;
    if (offset == Duration.zero) {
      return '${base}Z';
    }
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    final hours = abs.inHours.toString().padLeft(2, '0');
    final minutes = (abs.inMinutes % 60).toString().padLeft(2, '0');
    return '$base$sign$hours:$minutes';
  }

  String _redactStorageUrl(String url) {
    if (url.isEmpty) {
      return '';
    }
    try {
      final uri = Uri.parse(url);
      return '${uri.scheme}://${uri.host}${uri.path}';
    } catch (_) {
      return '[audioUrl]';
    }
  }

  Future<User> _ensureAuthReady({required bool forceRefreshToken}) async {
    User? user = _auth.currentUser;
    if (user == null) {
      user = await FirebaseSession.ensureAuthenticatedUser(
        forceTokenRefresh: forceRefreshToken,
      );
      return user;
    }

    final idToken = await user.getIdToken(forceRefreshToken);
    if (idToken == null || idToken.trim().isEmpty) {
      throw StateError('Unable to get auth token for callable request.');
    }

    if (kDebugMode) {
      debugPrint(
        '[Aivy] Service auth ready uid=${user.uid}, tokenPresent=${idToken.isNotEmpty}',
      );
    }
    return user;
  }

  bool _isUnauthenticated(FirebaseFunctionsException error) {
    final code = error.code.toLowerCase();
    final message = error.message?.toLowerCase() ?? '';
    return code == 'unauthenticated' || message.contains('unauthenticated');
  }

  String _formatFunctionsError(FirebaseFunctionsException error) {
    if (kDebugMode) {
      final message = error.message?.trim();
      debugPrint(
        '[Aivy] Callable error ${error.code}: ${message ?? '(no message)'}',
      );
    }
    return error.message ?? 'Unknown error';
  }

  /// Rebuilds `client_stats` + `meta/client_insights` on the server (Phase 3).
  Future<void> syncClientStats() async {
    await _ensureAuthReady(forceRefreshToken: true);
    final payload = await _buildBasePayload();
    final callable = _functions.httpsCallable('syncClientStats');
    try {
      await callable.call(<String, dynamic>{'timezone': payload['timezone']});
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        debugPrint('[Aivy] syncClientStats failed: ${_formatFunctionsError(e)}');
      }
    }
  }

  /// Server dashboard: due counts, follow-ups, total pending amount.
  Future<Map<String, dynamic>> fetchDashboardStats() async {
    await _ensureAuthReady(forceRefreshToken: true);
    final base = await _buildBasePayload();
    final callable = _functions.httpsCallable('getDashboardStats');
    final response = await callable.call(<String, dynamic>{
      'timeZone': base['timezone'],
    });
    final data = response.data;
    if (data is! Map) {
      return <String, dynamic>{};
    }
    return Map<String, dynamic>.from(data);
  }

  /// Marks a single in-app notification as read, or [markAllRead] for all.
  Future<int?> markNotificationRead({
    String? notificationId,
    bool markAllRead = false,
  }) async {
    await _ensureAuthReady(forceRefreshToken: true);
    final callable = _functions.httpsCallable('markNotificationRead');
    final response = await callable.call(<String, dynamic>{
      if (notificationId != null) 'notificationId': notificationId,
      'markAllRead': markAllRead,
    });
    final data = response.data;
    if (data is! Map) {
      return null;
    }
    final c = data['count'];
    return c is int ? c : null;
  }

  /// Marks a business order as dispatched (server sets [dispatchDate], payment follow-up).
  Future<String> markOrderDispatched(String orderId) async {
    final trimmed = orderId.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(orderId, 'orderId', 'must not be empty');
    }
    await _ensureAuthReady(forceRefreshToken: true);
    final base = await _buildBasePayload();
    final callable = _functions.httpsCallable('markOrderDispatched');
    final response = await callable.call(<String, dynamic>{
      'orderId': trimmed,
      'timezone': base['timezone'],
      'nowIso': base['nowIso'],
    });
    final data = response.data;
    if (data is Map && data['message'] is String) {
      return (data['message'] as String).trim();
    }
    return 'Order marked as dispatched.';
  }

  void dispose() {}
}
