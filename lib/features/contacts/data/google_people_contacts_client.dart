import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:http/http.dart' as http;

import '../../../core/firebase/firebase_session.dart';
import 'contact_service.dart';
import '../models/aivy_contact.dart';

/// Read-only Google Contacts via People API (`connections.list` +
/// `otherContacts.list` with pagination).
class GooglePeopleContactsClient {
  GooglePeopleContactsClient._();

  static const int _pageSize = 1000;

  static Uri _connectionsPageUri(String? pageToken) {
    final q = <String, String>{
      'personFields': 'names,emailAddresses,phoneNumbers',
      'pageSize': '$_pageSize',
    };
    if (pageToken != null && pageToken.isNotEmpty) {
      q['pageToken'] = pageToken;
    }
    return Uri.https('people.googleapis.com', '/v1/people/me/connections', q);
  }

  static Uri _otherContactsPageUri(String? pageToken) {
    final q = <String, String>{
      'readMask': 'names,emailAddresses,phoneNumbers',
      'pageSize': '$_pageSize',
    };
    if (pageToken != null && pageToken.isNotEmpty) {
      q['pageToken'] = pageToken;
    }
    return Uri.https('people.googleapis.com', '/v1/otherContacts', q);
  }

  static Future<List<Map<String, dynamic>>> _paginateConnections() async {
    final headers = await FirebaseSession.googleWorkspaceAuthHeaders();
    final all = <Map<String, dynamic>>[];
    String? pageToken;
    do {
      final res = await http.get(
        _connectionsPageUri(pageToken),
        headers: headers,
      );
      if (res.statusCode != 200) {
        throw StateError(
          'People connections ${res.statusCode}: '
          '${res.body.length > 200 ? '${res.body.substring(0, 200)}…' : res.body}',
        );
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) {
        break;
      }
      final batch = decoded['connections'];
      if (batch is List<dynamic>) {
        all.addAll(batch.whereType<Map<String, dynamic>>());
      }
      final next = '${decoded['nextPageToken'] ?? ''}'.trim();
      pageToken = next.isEmpty ? null : next;
    } while (pageToken != null);
    return all;
  }

  /// "Other contacts" (often newer auto-saved entries). Ignored if scope
  /// missing (403) or API error.
  static Future<List<Map<String, dynamic>>> _paginateOtherContacts() async {
    final headers = await FirebaseSession.googleWorkspaceAuthHeaders();
    final all = <Map<String, dynamic>>[];
    String? pageToken;
    try {
      do {
        final res = await http.get(
          _otherContactsPageUri(pageToken),
          headers: headers,
        );
        if (res.statusCode == 403) {
          if (kDebugMode) {
            debugPrint(
              '[Aivy] otherContacts: 403 — add contacts.other.readonly scope '
              'and Allow Google extras again.',
            );
          }
          return const [];
        }
        if (res.statusCode != 200) {
          if (kDebugMode) {
            debugPrint(
              '[Aivy] otherContacts ${res.statusCode}: ${res.body.length > 120 ? res.body.substring(0, 120) : res.body}',
            );
          }
          break;
        }
        final decoded = jsonDecode(res.body);
        if (decoded is! Map<String, dynamic>) {
          break;
        }
        final batch = decoded['otherContacts'];
        if (batch is List<dynamic>) {
          all.addAll(batch.whereType<Map<String, dynamic>>());
        }
        final next = '${decoded['nextPageToken'] ?? ''}'.trim();
        pageToken = next.isEmpty ? null : next;
      } while (pageToken != null);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[Aivy] otherContacts fetch: $e\n$st');
      }
    }
    return all;
  }

  static Future<List<Map<String, dynamic>>> _allRawMapsMerged() async {
    final connections = await _paginateConnections();
    final other = await _paginateOtherContacts();
    return <Map<String, dynamic>>[...connections, ...other];
  }

  /// All Google People rows merged (connections first, then other contacts).
  /// [connectionsCount] / [otherCount] are returned for UI totals.
  static Future<GooglePeopleLoadResult> loadAllConnectionsDetailed({
    required String ownerUid,
  }) async {
    final connections = await _paginateConnections();
    final other = await _paginateOtherContacts();

    final byId = <String, AivyContact>{};
    final seenPhone = <String>{};

    void tryAdd(AivyContact? c) {
      if (c == null) {
        return;
      }
      if (byId.containsKey(c.id)) {
        return;
      }
      if (c.phone.isNotEmpty) {
        if (seenPhone.contains(c.phone)) {
          return;
        }
        seenPhone.add(c.phone);
      }
      byId[c.id] = c;
    }

    for (final item in connections) {
      tryAdd(_mapItem(item, ownerUid, requirePhone: false));
    }
    for (final item in other) {
      tryAdd(_mapItem(item, ownerUid, requirePhone: false));
    }

    final list = byId.values.toList(growable: false)
      ..sort((a, b) => a.nameLower.compareTo(b.nameLower));

    return GooglePeopleLoadResult(
      contacts: list,
      connectionsSourceRows: connections.length,
      otherContactsSourceRows: other.length,
    );
  }

  /// All contacts with a name, sorted (dedupe by id + phone as above).
  static Future<List<AivyContact>> loadAllConnections({
    required String ownerUid,
  }) async {
    final r = await loadAllConnectionsDetailed(ownerUid: ownerUid);
    return r.contacts;
  }

  /// Name match + phone required; scans **all pages** (connections + other).
  static Future<List<AivyContact>> searchNamePrefix({
    required String ownerUid,
    required String queryPrefix,
    int limit = 20,
  }) async {
    final q = queryPrefix.trim().toLowerCase();
    if (q.isEmpty) {
      return const [];
    }
    final raw = await _allRawMapsMerged();
    final seenPhones = <String>{};
    final out = <AivyContact>[];
    for (final item in raw) {
      if (out.length >= limit) {
        break;
      }
      final c = _mapItem(item, ownerUid, requirePhone: true);
      if (c == null) {
        continue;
      }
      if (!ContactService.nameMatchesContactQuery(c.nameLower, q)) {
        continue;
      }
      if (seenPhones.contains(c.phone)) {
        continue;
      }
      seenPhones.add(c.phone);
      out.add(c);
    }
    return out;
  }

  static AivyContact? _mapItem(
    Map<String, dynamic> item,
    String ownerUid, {
    required bool requirePhone,
  }) {
    final resourceName = '${item['resourceName'] ?? ''}'.trim();
    if (resourceName.isEmpty) {
      return null;
    }

    var displayName = '';
    final names = item['names'];
    if (names is List && names.isNotEmpty) {
      final n0 = names.first;
      if (n0 is Map<String, dynamic>) {
        displayName =
            '${n0['displayName'] ?? n0['unstructuredName'] ?? ''}'.trim();
      }
    }
    if (displayName.isEmpty) {
      return null;
    }

    var email = '';
    final emails = item['emailAddresses'];
    if (emails is List && emails.isNotEmpty) {
      final e0 = emails.first;
      if (e0 is Map<String, dynamic>) {
        email = '${e0['value'] ?? ''}'.trim();
      }
    }

    var phone = '';
    final phones = item['phoneNumbers'];
    if (phones is List) {
      for (final p in phones) {
        if (p is! Map<String, dynamic>) {
          continue;
        }
        final raw =
            '${p['canonicalForm'] ?? p['value'] ?? ''}'.trim();
        final norm = ContactService.normalizeIndiaPhone(raw);
        if (norm != null) {
          phone = norm;
          break;
        }
      }
    }
    if (requirePhone && phone.isEmpty) {
      return null;
    }

    final safeId = resourceName.replaceAll(RegExp(r'[^\w\-]+'), '_');
    return AivyContact(
      id: 'google:$safeId',
      ownerUid: ownerUid,
      name: displayName,
      phone: phone,
      email: email,
      source: 'google_contacts',
    );
  }
}

/// Counts from People API before dedupe (for UI).
class GooglePeopleLoadResult {
  const GooglePeopleLoadResult({
    required this.contacts,
    required this.connectionsSourceRows,
    required this.otherContactsSourceRows,
  });

  final List<AivyContact> contacts;
  final int connectionsSourceRows;
  final int otherContactsSourceRows;

  int get sourceRowsTotal =>
      connectionsSourceRows + otherContactsSourceRows;
}
