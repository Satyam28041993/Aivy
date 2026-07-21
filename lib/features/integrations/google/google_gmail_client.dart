import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/firebase/firebase_session.dart';

/// Minimal `users.messages.send` (plain UTF-8 body).
class GoogleGmailClient {
  GoogleGmailClient._();

  static final Uri _sendUri = Uri.parse(
    'https://gmail.googleapis.com/gmail/v1/users/me/messages/send',
  );

  static String _rfc822({
    required String to,
    required String subject,
    required String body,
  }) {
    final subj = subject.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
    final b = body.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return 'To: $to\r\n'
        'Subject: $subj\r\n'
        'Content-Type: text/plain; charset=UTF-8\r\n'
        '\r\n'
        '$b';
  }

  static String _urlSafeBase64Raw(String rfc) {
    final bytes = utf8.encode(rfc);
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static Future<void> sendPlainText({
    required String to,
    required String subject,
    required String body,
  }) async {
    final headers = await FirebaseSession.googleWorkspaceAuthHeaders();
    final raw = _urlSafeBase64Raw(
      _rfc822(to: to.trim(), subject: subject.trim(), body: body),
    );
    final res = await http.post(
      _sendUri,
      headers: <String, String>{
        ...headers,
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: jsonEncode(<String, dynamic>{'raw': raw}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'Gmail API ${res.statusCode}: '
        '${res.body.length > 280 ? '${res.body.substring(0, 280)}…' : res.body}',
      );
    }
  }
}
