import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/firebase/firebase_session.dart';

/// Minimal Calendar v3 insert into the user's primary calendar.
class GoogleCalendarClient {
  GoogleCalendarClient._();

  static final Uri _eventsUri = Uri.parse(
    'https://www.googleapis.com/calendar/v3/calendars/primary/events',
  );

  /// Creates a single timed event. Times are sent as UTC; Calendar shows them
  /// in the user's local zone in the Google app.
  static Future<String> insertTimedEvent({
    required String summary,
    required DateTime startLocal,
    Duration duration = const Duration(hours: 1),
  }) async {
    final headers = await FirebaseSession.googleWorkspaceAuthHeaders();
    final startUtc = startLocal.toUtc();
    final endUtc = startLocal.add(duration).toUtc();
    final body = <String, dynamic>{
      'summary': summary,
      'start': <String, dynamic>{
        'dateTime': startUtc.toIso8601String(),
        'timeZone': 'UTC',
      },
      'end': <String, dynamic>{
        'dateTime': endUtc.toIso8601String(),
        'timeZone': 'UTC',
      },
    };
    final res = await http.post(
      _eventsUri,
      headers: <String, String>{
        ...headers,
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: jsonEncode(body),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'Calendar API ${res.statusCode}: '
        '${res.body.length > 280 ? '${res.body.substring(0, 280)}…' : res.body}',
      );
    }
    final map = jsonDecode(res.body);
    if (map is! Map<String, dynamic>) {
      return '';
    }
    return '${map['htmlLink'] ?? map['id'] ?? ''}'.trim();
  }
}
