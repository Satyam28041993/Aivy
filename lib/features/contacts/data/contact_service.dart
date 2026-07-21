import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

import '../models/aivy_contact.dart';
import 'google_people_contacts_client.dart';

/// Firestore-backed contacts for CRM / WhatsApp name resolution.
class ContactService {
  ContactService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('contacts');

  /// Normalises to digits; expects India `91` + 10 digits when possible.
  static String? normalizeIndiaPhone(String raw) {
    final d = raw.replaceAll(RegExp(r'\D'), '');
    if (d.length == 12 && d.startsWith('91')) {
      return d;
    }
    if (d.length == 10) {
      return '91$d';
    }
    if (d.length >= 10 && d.length <= 15) {
      return d;
    }
    return null;
  }

  Future<String> addContact({
    required String ownerUid,
    required String name,
    required String phone,
    String company = '',
    String email = '',
    List<String> tags = const [],
    String notes = '',
  }) async {
    final n = name.trim();
    if (n.isEmpty) {
      throw ArgumentError('Name is required');
    }
    final p = normalizeIndiaPhone(phone);
    if (p == null) {
      throw ArgumentError.value(phone, 'phone', 'Use 91XXXXXXXXXX or 10-digit');
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final c = AivyContact(
      id: '',
      ownerUid: ownerUid,
      name: n,
      phone: p,
      company: company,
      email: email,
      tags: tags,
      notes: notes,
      source: 'manual',
    );
    final ref = await _col.add(c.toCreateMap(ownerUid, nowMs));
    return ref.id;
  }

  Future<void> updateContact({
    required String ownerUid,
    required String contactId,
    required String name,
    required String phone,
    String company = '',
    String email = '',
    List<String> tags = const [],
    String notes = '',
  }) async {
    final n = name.trim();
    if (n.isEmpty) {
      throw ArgumentError('Name is required');
    }
    final p = normalizeIndiaPhone(phone);
    if (p == null) {
      throw ArgumentError.value(phone, 'phone', 'Use 91XXXXXXXXXX or 10-digit');
    }
    final ref = _col.doc(contactId);
    final snap = await ref.get();
    if (!snap.exists) {
      throw StateError('Contact not found');
    }
    final o = '${snap.data()?['ownerUid'] ?? ''}'.trim();
    if (o != ownerUid) {
      throw StateError('Not allowed');
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final c = AivyContact(
      id: contactId,
      ownerUid: ownerUid,
      name: n,
      phone: p,
      company: company,
      email: email,
      tags: tags,
      notes: notes,
    );
    await ref.set(c.toUpdateMap(nowMs), SetOptions(merge: true));
  }

  Future<void> deleteContact({
    required String ownerUid,
    required String contactId,
  }) async {
    final ref = _col.doc(contactId);
    final snap = await ref.get();
    if (!snap.exists) {
      return;
    }
    final o = '${snap.data()?['ownerUid'] ?? ''}'.trim();
    if (o != ownerUid) {
      throw StateError('Not allowed');
    }
    await ref.delete();
  }

  /// Bulk create from parsed rows (e.g. Excel). Skips invalid rows.
  /// [rows] must not include the header row.
  Future<ContactBulkImportResult> bulkImportContacts({
    required String ownerUid,
    required List<ContactImportRow> rows,
  }) async {
    var imported = 0;
    var skipped = 0;
    const chunk = 400;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < rows.length; i += chunk) {
      final batch = _firestore.batch();
      final slice = rows.skip(i).take(chunk);
      for (final r in slice) {
        final n = r.name.trim();
        final p = normalizeIndiaPhone(r.phone);
        if (n.isEmpty || p == null) {
          skipped++;
          continue;
        }
        final ref = _col.doc();
        final c = AivyContact(
          id: ref.id,
          ownerUid: ownerUid,
          name: n,
          phone: p,
          company: r.company.trim(),
          email: r.email.trim(),
          tags: r.tags,
          notes: r.notes.trim(),
          source: 'excel_import',
        );
        batch.set(ref, c.toCreateMap(ownerUid, nowMs));
        imported++;
      }
      await batch.commit();
    }
    return ContactBulkImportResult(imported: imported, skipped: skipped);
  }

  /// Prefix match for short tokens; substring for [query] length ≥ 3 (e.g. "Jayesh"
  /// matches "Mr Jayesh Kumar").
  static bool nameMatchesContactQuery(String nameLower, String queryLower) {
    final q = queryLower.trim();
    if (q.isEmpty) {
      return false;
    }
    if (nameLower.startsWith(q)) {
      return true;
    }
    if (q.length < 3) {
      return false;
    }
    return nameLower.contains(q);
  }

  /// Prefix match on name (no composite Firestore index required).
  Future<List<AivyContact>> searchContactsByName(
    String ownerUid,
    String query, {
    int limit = 25,
    int scanCap = 500,
  }) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return const [];
    }
    final snap = await _col
        .where('ownerUid', isEqualTo: ownerUid)
        .limit(scanCap)
        .get();
    final rows = snap.docs
        .map((d) => AivyContact.fromDoc(d.id, d.data()))
        .where((c) => nameMatchesContactQuery(c.nameLower, q))
        .toList(growable: false);
    rows.sort((a, b) => a.nameLower.compareTo(b.nameLower));
    if (rows.length <= limit) {
      return rows;
    }
    return rows.sublist(0, limit);
  }

  /// CRM matches first, then Google Contacts (same name prefix) without
  /// duplicating phone numbers. Google rows use ids like `google:…`.
  Future<List<AivyContact>> searchContactsByNameIncludingGoogle(
    String ownerUid,
    String query, {
    int limit = 25,
    int scanCap = 500,
  }) async {
    final crm = await searchContactsByName(
      ownerUid,
      query,
      limit: limit,
      scanCap: scanCap,
    );
    var google = const <AivyContact>[];
    try {
      google = await GooglePeopleContactsClient.searchNamePrefix(
        ownerUid: ownerUid,
        queryPrefix: query,
        limit: limit,
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[Aivy] Google contacts search skipped: $e\n$st');
      }
    }
    final seen = <String>{for (final c in crm) c.phone};
    final merged = List<AivyContact>.from(crm);
    for (final g in google) {
      if (merged.length >= limit) {
        break;
      }
      if (seen.contains(g.phone)) {
        continue;
      }
      seen.add(g.phone);
      merged.add(g);
    }
    return merged;
  }

  Future<AivyContact?> getContactByPhone(String ownerUid, String phone) async {
    final p = normalizeIndiaPhone(phone);
    if (p == null) {
      return null;
    }
    final snap = await _col.where('ownerUid', isEqualTo: ownerUid).limit(500).get();
    for (final d in snap.docs) {
      final c = AivyContact.fromDoc(d.id, d.data());
      if (c.phone == p) {
        return c;
      }
    }
    return null;
  }

  /// Normalized E.164 (India) phone → CRM display name. One Firestore read batch.
  Future<Map<String, String>> phoneToNameMap(String ownerUid) async {
    final uid = ownerUid.trim();
    if (uid.isEmpty) {
      return const <String, String>{};
    }
    final snap = await _col.where('ownerUid', isEqualTo: uid).limit(500).get();
    final out = <String, String>{};
    for (final d in snap.docs) {
      final c = AivyContact.fromDoc(d.id, d.data());
      final p = c.phone.trim();
      final n = c.name.trim();
      if (p.isEmpty || n.isEmpty) {
        continue;
      }
      out[p] = n;
    }
    return out;
  }

  Stream<List<AivyContact>> watchContacts(String ownerUid, {int limit = 500}) {
    return _col
        .where('ownerUid', isEqualTo: ownerUid)
        .limit(limit)
        .snapshots()
        .map((s) {
          final list = s.docs
              .map((d) => AivyContact.fromDoc(d.id, d.data()))
              .toList(growable: false);
          list.sort((a, b) => a.nameLower.compareTo(b.nameLower));
          return list;
        });
  }

  Future<AivyContact?> getById(String ownerUid, String id) async {
    final snap = await _col.doc(id).get();
    if (!snap.exists) {
      return null;
    }
    final data = snap.data();
    if (data == null) {
      return null;
    }
    if ('${data['ownerUid'] ?? ''}'.trim() != ownerUid) {
      return null;
    }
    return AivyContact.fromDoc(snap.id, data);
  }
}

/// One row from Excel (after header).
class ContactImportRow {
  const ContactImportRow({
    required this.name,
    required this.phone,
    this.company = '',
    this.email = '',
    this.tags = const [],
    this.notes = '',
  });

  final String name;
  final String phone;
  final String company;
  final String email;
  final List<String> tags;
  final String notes;
}

class ContactBulkImportResult {
  const ContactBulkImportResult({
    required this.imported,
    required this.skipped,
  });

  final int imported;
  final int skipped;
}
