import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/firebase/firebase_session.dart';

/// One row for inbox list UI (Gmail API read-only).
class GmailMessageSummary {
  const GmailMessageSummary({
    required this.id,
    required this.subject,
    required this.from,
    required this.snippet,
  });

  final String id;
  final String subject;
  final String from;
  final String snippet;
}

/// Gmail `users.messages.list` + lightweight `get` (metadata).
class GoogleGmailReadClient {
  GoogleGmailReadClient._();

  static Uri _listUri(int maxResults) => Uri.parse(
    'https://gmail.googleapis.com/gmail/v1/users/me/messages'
    '?maxResults=$maxResults&labelIds=INBOX',
  );

  static Uri _getUri(String id) => Uri.parse(
    'https://gmail.googleapis.com/gmail/v1/users/me/messages/$id'
    '?format=metadata'
    '&metadataHeaders=Subject'
    '&metadataHeaders=From',
  );

  static String _header(
    List<dynamic>? headers,
    String name,
  ) {
    if (headers == null) {
      return '';
    }
    final want = name.toLowerCase();
    for (final h in headers) {
      if (h is! Map<String, dynamic>) {
        continue;
      }
      if ('${h['name'] ?? ''}'.toLowerCase() == want) {
        return '${h['value'] ?? ''}'.trim();
      }
    }
    return '';
  }

  static Future<List<GmailMessageSummary>> listRecentInbox({
    int maxResults = 25,
  }) async {
    final auth = await FirebaseSession.googleWorkspaceAuthHeaders();
    final listRes = await http.get(_listUri(maxResults), headers: auth);
    if (listRes.statusCode < 200 || listRes.statusCode >= 300) {
      throw StateError(
        'Gmail list ${listRes.statusCode}: '
        '${listRes.body.length > 200 ? '${listRes.body.substring(0, 200)}…' : listRes.body}',
      );
    }
    final listJson = jsonDecode(listRes.body);
    if (listJson is! Map<String, dynamic>) {
      return const [];
    }
    final messages = listJson['messages'];
    if (messages is! List<dynamic>) {
      return const [];
    }
    final out = <GmailMessageSummary>[];
    for (final m in messages) {
      if (m is! Map<String, dynamic>) {
        continue;
      }
      final id = '${m['id'] ?? ''}'.trim();
      if (id.isEmpty) {
        continue;
      }
      final getRes = await http.get(_getUri(id), headers: auth);
      if (getRes.statusCode < 200 || getRes.statusCode >= 300) {
        continue;
      }
      final msgJson = jsonDecode(getRes.body);
      if (msgJson is! Map<String, dynamic>) {
        continue;
      }
      final payload = msgJson['payload'];
      final headersList =
          payload is Map<String, dynamic> ? payload['headers'] as List<dynamic>? : null;
      final subject = _header(headersList, 'Subject');
      final from = _header(headersList, 'From');
      final snippet = '${msgJson['snippet'] ?? ''}'.trim();
      out.add(
        GmailMessageSummary(
          id: id,
          subject: subject.isEmpty ? '(No subject)' : subject,
          from: from.isEmpty ? '—' : from,
          snippet: snippet,
        ),
      );
    }
    return out;
  }
}
