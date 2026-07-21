import 'package:cloud_firestore/cloud_firestore.dart';

/// Firestore `contacts` document (root collection).
///
/// [ownerUid] scopes rows per signed-in user (required for security rules).
/// User-facing fields match product spec; [ownerUid] is internal.
class AivyContact {
  const AivyContact({
    required this.id,
    required this.ownerUid,
    required this.name,
    required this.phone,
    this.company = '',
    this.email = '',
    this.tags = const [],
    this.notes = '',
    this.source,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
  });

  final String id;
  final String ownerUid;
  final String name;
  final String phone;
  final String company;
  final String email;
  final List<String> tags;
  final String notes;
  final String? source;
  final int createdAtMs;
  final int updatedAtMs;

  /// Lowercase name for matching (Firestore may also store [nameLower]).
  String get nameLower => name.trim().toLowerCase();

  static AivyContact fromDoc(String id, Map<String, dynamic> data) {
    final tagsRaw = data['tags'];
    final tags = <String>[];
    if (tagsRaw is List) {
      for (final e in tagsRaw) {
        if (e is String && e.trim().isNotEmpty) {
          tags.add(e.trim());
        }
      }
    }
    return AivyContact(
      id: id,
      ownerUid: '${data['ownerUid'] ?? ''}'.trim(),
      name: '${data['name'] ?? ''}'.trim(),
      phone: '${data['phone'] ?? ''}'.trim(),
      company: '${data['company'] ?? ''}'.trim(),
      email: '${data['email'] ?? ''}'.trim(),
      tags: tags,
      notes: '${data['notes'] ?? ''}'.trim(),
      source: data['source'] is String ? data['source'] as String : null,
      createdAtMs: (data['createdAtMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (data['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toCreateMap(String ownerUid, int nowMs) {
    final nl = name.trim().toLowerCase();
    return {
      'ownerUid': ownerUid,
      'name': name.trim(),
      'nameLower': nl,
      'phone': phone.trim(),
      'company': company.trim(),
      'email': email.trim(),
      'tags': tags,
      'notes': notes.trim(),
      'source': source ?? 'manual',
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtMs': nowMs,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': nowMs,
    };
  }

  Map<String, dynamic> toUpdateMap(int nowMs) {
    final nl = name.trim().toLowerCase();
    return {
      'name': name.trim(),
      'nameLower': nl,
      'phone': phone.trim(),
      'company': company.trim(),
      'email': email.trim(),
      'tags': tags,
      'notes': notes.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': nowMs,
    };
  }
}
