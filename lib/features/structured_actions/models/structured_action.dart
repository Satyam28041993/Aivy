import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/name_normalize.dart';

/// Single business record in `users/{uid}/structured_actions`.
class StructuredAction {
  const StructuredAction({
    this.id,
    required this.type,
    required this.subType,
    this.name = '',
    this.nameLower = '',
    this.aliases = const [],
    this.amount,
    this.date,
    this.note,
    this.status = 'pending',
    required this.createdAt,
    this.title,
    this.clientId,
    this.linkedPaymentId,
    this.legacyMigrated = false,
    this.migratedToPaymentId,
  });

  final String? id;
  final String type;
  final String subType;
  final String name;

  /// [normalizeName] of [name] for indexed matching (Phase 5).
  final String nameLower;
  final List<String> aliases;
  final double? amount;
  final DateTime? date;
  final String? note;
  final String status;
  final DateTime createdAt;

  /// Follow-up only: human-readable title.
  final String? title;

  /// Optional CRM link (payments).
  final String? clientId;
  final String? linkedPaymentId;

  /// Legacy payment due migrated into `users/.../payments`.
  final bool legacyMigrated;
  final String? migratedToPaymentId;

  Map<String, dynamic> toFirestore() {
    final nl = nameLower.isNotEmpty
        ? nameLower
        : (name.isNotEmpty ? normalizeName(name) : '');
    final m = <String, dynamic>{
      'type': type,
      'subType': subType,
      'name': name,
      'nameLower': nl,
      'status': status,
      if (amount != null) 'amount': amount,
      if (date != null) 'date': Timestamp.fromDate(date!),
      if (note != null && note!.trim().isNotEmpty) 'note': note!.trim(),
      if (title != null && title!.trim().isNotEmpty) 'title': title!.trim(),
      if (clientId != null && clientId!.trim().isNotEmpty)
        'clientId': clientId!.trim(),
      if (linkedPaymentId != null && linkedPaymentId!.trim().isNotEmpty)
        'linkedPaymentId': linkedPaymentId!.trim(),
    };
    if (aliases.isNotEmpty) {
      m['aliases'] = aliases;
    }
    return m;
  }

  static StructuredAction fromDoc(String id, Map<String, dynamic> d) {
    final dateRaw = d['date'];
    DateTime? date;
    if (dateRaw is Timestamp) {
      date = dateRaw.toDate();
    }
    final amountRaw = d['amount'];
    final st = (d['status'] as String? ?? 'pending').trim();
    final nameStr = (d['name'] as String? ?? '').trim();
    final rawNl = d['nameLower'] as String?;
    final nl = (rawNl != null && rawNl.isNotEmpty)
        ? rawNl
        : (nameStr.isNotEmpty ? normalizeName(nameStr) : '');
    final al = d['aliases'];
    List<String> aliases = const [];
    if (al is List) {
      aliases = al
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    final ti = (d['title'] as String? ?? '').trim();
    final cid = (d['clientId'] as String? ?? '').trim();
    final lid = (d['linkedPaymentId'] as String? ?? '').trim();
    final mig = (d['migratedToPaymentId'] as String? ?? '').trim();
    return StructuredAction(
      id: id,
      type: (d['type'] as String? ?? '').trim(),
      subType: (d['subType'] as String? ?? '').trim(),
      name: nameStr,
      nameLower: nl,
      aliases: aliases,
      amount: amountRaw is num ? amountRaw.toDouble() : null,
      date: date,
      note: (d['note'] as String? ?? '').trim().isEmpty
          ? null
          : d['note'] as String?,
      status: st.isEmpty ? 'pending' : st,
      createdAt: (d['createdAt'] is Timestamp)
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.fromMillisecondsSinceEpoch(
              (d['createdAtMs'] as num?)?.toInt() ?? 0,
            ),
      title: ti.isEmpty ? null : ti,
      clientId: cid.isEmpty ? null : cid,
      linkedPaymentId: lid.isEmpty ? null : lid,
      legacyMigrated: d['legacyMigrated'] == true,
      migratedToPaymentId: mig.isEmpty ? null : mig,
    );
  }
}
