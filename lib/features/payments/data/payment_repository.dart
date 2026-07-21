import 'package:cloud_firestore/cloud_firestore.dart';

import '../../clients/data/client_repository.dart';
import '../../clients/models/client.dart';
import '../../structured_actions/data/structured_action_repository.dart';
import '../../structured_actions/utils/name_normalize.dart';
import '../models/client_pending_dues_summary.dart';
import '../models/payment_record.dart';
import '../utils/payment_settlement_utils.dart';

class PaymentRepository {
  PaymentRepository({
    FirebaseFirestore? firestore,
    ClientRepository? clients,
    StructuredActionRepository? structured,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _clients = clients ?? ClientRepository(),
        _structured = structured ?? StructuredActionRepository();

  final FirebaseFirestore _firestore;
  final ClientRepository _clients;
  final StructuredActionRepository _structured;

  CollectionReference<Map<String, dynamic>> _col(String userId) {
    return _firestore.collection('users').doc(userId).collection('payments');
  }

  /// Sum of [effectiveRemaining] for open payment dues + legacy structured open
  /// payment rows for this client — authoritative client outstanding.
  Future<void> syncClientOutstandingForClient(
    String userId,
    String clientId,
  ) async {
    final cid = clientId.trim();
    if (cid.isEmpty) {
      return;
    }
    final client = await _clients.getById(userId, cid);
    if (client == null) {
      return;
    }
    var total = 0.0;
    final paySnap = await _col(userId).where('clientId', isEqualTo: cid).get();
    for (final d in paySnap.docs) {
      final p = PaymentRecord.fromDoc(d.id, d.data());
      if (p.isOpenPaymentDue) {
        total += p.effectiveRemaining;
      }
    }
    final leg = await _structured.getAllOpenPaymentActions(userId);
    final nl = client.nameLower;
    for (final a in leg) {
      final match = (a.clientId != null && a.clientId!.trim() == cid) ||
          (a.nameLower.isNotEmpty && a.nameLower == nl) ||
          (normalizeName(a.name) == nl);
      if (!match) {
        continue;
      }
      final amt = a.amount ?? 0;
      if (amt > 0) {
        total += amt;
      }
    }
    await _clients.setOutstandingBalance(userId, cid, total);
  }

  /// Open dues on `payments` whose [clientNameLower] matches [normalizedName]
  /// (exact, prefix, or contains). Sorted: oldest due, then highest remaining.
  Future<List<PaymentRecord>> searchOpenPaymentDuesByNameNormalized(
    String userId,
    String normalizedName,
  ) async {
    final n = normalizedName.trim();
    if (n.isEmpty) {
      return const [];
    }
    final all = await getAllOpenDues(userId);
    bool matches(PaymentRecord p) {
      final pl = p.clientNameLower.trim();
      if (pl.isEmpty) {
        return normalizeName(p.clientName) == n;
      }
      return pl == n || pl.startsWith(n) || pl.contains(n);
    }

    final out = all.where(matches).toList()
      ..sort(PaymentRecord.compareOpenDuesForReceiptPicker);
    return out;
  }

  Future<List<PaymentRecord>> getPendingPayments(
    String userId,
    String clientId,
  ) async {
    final cid = clientId.trim();
    if (cid.isEmpty) {
      return const [];
    }
    final snap = await _col(userId).where('clientId', isEqualTo: cid).get();
    final out = snap.docs
        .map((d) => PaymentRecord.fromDoc(d.id, d.data()))
        .where((p) => p.isOpenPaymentDue)
        .toList();
    out.sort(PaymentRecord.compareOpenDuesForReceiptPicker);
    return out;
  }

  /// All open dues for dashboard-style lists; excludes paid/received log rows.
  Future<List<PaymentRecord>> getAllOpenDues(String userId) async {
    final snap = await _col(userId).get();
    final out = <PaymentRecord>[];
    for (final d in snap.docs) {
      final p = PaymentRecord.fromDoc(d.id, d.data());
      if (!p.isOpenPaymentDue) {
        continue;
      }
      out.add(p);
    }
    out.sort((a, b) => (a.dueDateMs ?? 0).compareTo(b.dueDateMs ?? 0));
    return out;
  }

  /// Open payment dues grouped by client — totals use **effectiveRemaining**.
  /// Includes legacy [structured_actions] open payment rows so the list matches
  /// dashboard / CRM clients that lack a `payments` doc yet.
  Future<List<ClientPendingDuesSummary>> getPendingDuesGroupedByClient(
    String userId,
  ) async {
    final byClient = await _openDuesMapGroupedByClientId(userId);
    return _summariesFromClientMap(byClient);
  }

  List<ClientPendingDuesSummary> _summariesFromClientMap(
    Map<String, List<PaymentRecord>> byClient,
  ) {
    final out = <ClientPendingDuesSummary>[];
    for (final e in byClient.entries) {
      final lines = List<PaymentRecord>.from(e.value)
        ..sort(PaymentRecord.compareOpenDuesForReceiptPicker);
      final name = lines.isNotEmpty
          ? (lines.first.clientName.trim().isNotEmpty
                ? lines.first.clientName
                : e.key)
          : e.key;
      final total = lines.fold<double>(
        0,
        (s, p) => s + p.effectiveRemaining,
      );
      out.add(
        ClientPendingDuesSummary(
          clientId: e.key,
          clientName: name,
          totalPending: total,
          dues: lines,
        ),
      );
    }
    out.sort((a, b) => b.totalPending.compareTo(a.totalPending));
    return out;
  }

  Future<Map<String, List<PaymentRecord>>> _openDuesMapGroupedByClientId(
    String userId,
  ) async {
    final open = await getAllOpenDues(userId);
    return _buildGroupedMapFromOpenList(userId, open);
  }

  Future<Map<String, List<PaymentRecord>>> _buildGroupedMapFromOpenList(
    String userId,
    List<PaymentRecord> open,
  ) async {
    final byClient = <String, List<PaymentRecord>>{};
    final orphans = <PaymentRecord>[];
    for (final p in open) {
      final id = p.clientId.trim();
      if (id.isEmpty) {
        orphans.add(p);
        continue;
      }
      byClient.putIfAbsent(id, () => []).add(p);
    }
    await _resolveOrphanOpenDuesByClientName(userId, orphans, byClient);
    await _mergeLegacyStructuredOpenDues(userId, byClient);
    return byClient;
  }

  /// Payment docs with no [clientId] still appear in pending-by-client lists when
  /// the name matches a CRM client; otherwise they keep a stable orphan bucket.
  Future<void> _resolveOrphanOpenDuesByClientName(
    String userId,
    List<PaymentRecord> orphans,
    Map<String, List<PaymentRecord>> byClient,
  ) async {
    if (orphans.isEmpty) {
      return;
    }
    final clients = await _clients.listAll(userId);
    for (final p in orphans) {
      final nl = p.clientNameLower.trim().isNotEmpty
          ? p.clientNameLower.trim()
          : normalizeName(p.clientName);
      if (nl.isEmpty && p.clientName.trim().isEmpty) {
        continue;
      }
      Client? hit;
      for (final c in clients) {
        if (c.nameLower == nl ||
            normalizeName(c.name) == nl ||
            c.nameLower == normalizeName(p.clientName)) {
          hit = c;
          break;
        }
      }
      final cid = hit?.id.trim().isNotEmpty == true
          ? hit!.id
          : '__orphan__${p.id}';
      final cname = hit != null && hit.name.trim().isNotEmpty
          ? hit.name.trim()
          : (p.clientName.trim().isNotEmpty ? p.clientName.trim() : 'Client');
      final fixed = p.withClientResolution(
        newClientId: cid,
        newClientName: cname,
      );
      byClient.putIfAbsent(cid, () => []).add(fixed);
    }
  }

  Future<void> _mergeLegacyStructuredOpenDues(
    String userId,
    Map<String, List<PaymentRecord>> byClient,
  ) async {
    final legacy = await _structured.getAllOpenPaymentActions(userId);
    if (legacy.isEmpty) {
      return;
    }
    final clients = await _clients.listAll(userId);
    final byId = {for (final c in clients) c.id: c};
    for (final a in legacy) {
      var cid = (a.clientId ?? '').trim();
      var display = a.name.trim();
      if (cid.isEmpty) {
        final nl =
            a.nameLower.isNotEmpty ? a.nameLower : normalizeName(a.name);
        if (nl.isEmpty) {
          continue;
        }
        Client? hit;
        for (final c in clients) {
          if (c.nameLower == nl ||
              normalizeName(c.name) == nl ||
              c.nameLower == normalizeName(a.name)) {
            hit = c;
            break;
          }
        }
        if (hit == null) {
          continue;
        }
        cid = hit.id;
        display = hit.name;
      } else {
        final cl = byId[cid];
        if (cl != null && cl.name.trim().isNotEmpty) {
          display = cl.name.trim();
        } else if (display.isEmpty && cl != null) {
          display = cl.name.trim();
        }
        if (display.isEmpty) {
          display = 'Client';
        }
      }
      final synthetic = PaymentRecord.fromOpenStructuredDue(
        a,
        resolvedClientId: cid,
        resolvedClientName: display,
      );
      byClient.putIfAbsent(cid, () => []).add(synthetic);
    }
  }

  Stream<List<ClientPendingDuesSummary>> watchPendingDuesGroupedByClient(
    String userId,
  ) {
    return _col(userId).snapshots().asyncMap((snap) async {
      final open = snap.docs
          .map((d) => PaymentRecord.fromDoc(d.id, d.data()))
          .where((p) => p.isOpenPaymentDue)
          .toList();
      final byClient = await _buildGroupedMapFromOpenList(userId, open);
      return _summariesFromClientMap(byClient);
    });
  }

  Future<String> createPaymentDue({
    required String userId,
    required String clientId,
    required String clientName,
    required double amount,
    required int dueDateMs,
    String? note,
    String? invoiceLabel,
  }) async {
    final ref = _col(userId).doc();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dueLower = DateTime.fromMillisecondsSinceEpoch(dueDateMs);
    final now = DateTime.now();
    final overdue =
        DateTime(dueLower.year, dueLower.month, dueLower.day)
            .isBefore(DateTime(now.year, now.month, now.day));
    await ref.set({
      'type': 'payment_due',
      'subType': 'payment_due',
      'clientId': clientId,
      'clientName': clientName.trim(),
      'clientNameLower': normalizeName(clientName),
      'amount': amount,
      'paymentVersion': 2,
      'originalAmount': amount,
      'paidAmount': 0.0,
      'remainingAmount': amount,
      'receiptCount': 0,
      'status': overdue ? 'overdue' : 'pending',
      'dueDateMs': dueDateMs,
      'dueDate': Timestamp.fromMillisecondsSinceEpoch(dueDateMs),
      if (invoiceLabel != null && invoiceLabel.trim().isNotEmpty)
        'invoiceLabel': invoiceLabel.trim(),
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtMs': nowMs,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': nowMs,
    });
    return ref.id;
  }

  /// Creates a `payments` due from legacy [structured_actions] and marks the
  /// legacy row migrated. Idempotent if already migrated.
  Future<String> migrateStructuredPaymentDueToPayments({
    required String userId,
    required String structuredActionId,
    required String clientId,
    required String clientDisplayName,
  }) async {
    final leg = await _structured.tryGetById(userId, structuredActionId);
    if (leg == null || leg.type != 'payment') {
      throw StateError('Legacy structured payment not found');
    }
    if (leg.legacyMigrated &&
        leg.migratedToPaymentId != null &&
        leg.migratedToPaymentId!.trim().isNotEmpty) {
      return leg.migratedToPaymentId!.trim();
    }
    final amt = leg.amount ?? 0.0;
    if (amt <= 0) {
      throw StateError('Legacy payment has no positive amount');
    }
    final dueMs =
        leg.date?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch;
    final newId = await createPaymentDue(
      userId: userId,
      clientId: clientId,
      clientName: clientDisplayName.trim(),
      amount: amt,
      dueDateMs: dueMs,
      note: leg.note,
    );
    await _structured.markPaymentLegacyMigrated(
      userId,
      structuredActionId,
      newId,
    );
    await syncClientOutstandingForClient(userId, clientId);
    return newId;
  }

  /// Transaction-safe settlement: receipt row + due update. Unlinked receipts
  /// (no [linkedPaymentId]) only append receipt and sync client outstanding.
  Future<String> settlePaymentReceived({
    required String userId,
    required String clientId,
    required String clientName,
    required double receivedAmount,
    String? linkedPaymentId,
    String? paymentNote,
    String? note,
    String? paymentMode,
    Object? receiptNumber,
    int? receivedAtMs,
  }) async {
    if (receivedAmount <= 0) {
      throw ArgumentError.value(receivedAmount, 'receivedAmount', 'must be > 0');
    }
    final noteOut = (paymentNote ?? note)?.trim();
    final linked = linkedPaymentId?.trim() ?? '';
    if (linked.isEmpty) {
      return _appendStandaloneReceipt(
        userId: userId,
        clientId: clientId,
        clientName: clientName,
        receivedAmount: receivedAmount,
        noteOut: noteOut,
        paymentMode: paymentMode,
        receiptNumber: receiptNumber,
        receivedAtMs: receivedAtMs,
      );
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final recvMs = receivedAtMs ?? nowMs;

    final receiptId = await _firestore.runTransaction<String>((txn) async {
      final dueRef = _col(userId).doc(linked);
      final dueSnap = await txn.get(dueRef);
      if (!dueSnap.exists || dueSnap.data() == null) {
        throw StateError('Linked payment due not found');
      }
      final dd = dueSnap.data()!;
      final due = PaymentRecord.fromDoc(dueSnap.id, dd);
      if (!due.isPaymentDueDocument) {
        throw StateError('Linked document is not a payment due');
      }
      final orig = due.effectiveOriginal;
      final remBefore = due.effectiveRemaining;
      if (receivedAmount > remBefore + 1e-6) {
        throw StateError('Received amount exceeds remaining balance');
      }
      final paidBefore = due.effectivePaid;
      final newPaid = paidBefore + receivedAmount;
      var newRem = orig - newPaid;
      if (newRem < 0) {
        newRem = 0;
      }
      final newStatus = newRem <= 1e-9 ? 'received' : 'partial_pending';
      final receiptRef = _col(userId).doc();
      final rid = receiptRef.id;
      final receipt = <String, dynamic>{
        'type': 'payment',
        'subType': 'payment_received',
        'clientId': clientId,
        'clientName': clientName.trim(),
        'amount': receivedAmount,
        'status': 'received',
        'linkedPaymentId': linked,
        'voided': false,
        'receivedAt': Timestamp.fromMillisecondsSinceEpoch(recvMs),
        'receivedAtMs': recvMs,
        'createdAt': FieldValue.serverTimestamp(),
        'createdAtMs': nowMs,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtMs': nowMs,
      };
      if (noteOut != null && noteOut.isNotEmpty) {
        receipt['paymentNote'] = noteOut;
        receipt['note'] = noteOut;
      }
      final mode = paymentMode?.trim();
      if (mode != null && mode.isNotEmpty) {
        receipt['paymentMode'] = mode;
      }
      if (receiptNumber != null &&
          receiptNumber.toString().trim().isNotEmpty) {
        receipt['receiptNumber'] = receiptNumber is num
            ? receiptNumber
            : receiptNumber.toString().trim();
      }
      txn.set(receiptRef, receipt);

      final duePatch = <String, dynamic>{
        'paidAmount': newPaid,
        'remainingAmount': newRem,
        'receiptCount': (due.receiptCount ?? 0) + 1,
        'lastReceivedAt': Timestamp.fromMillisecondsSinceEpoch(recvMs),
        'lastReceivedAtMs': recvMs,
        'lastReceiptId': rid,
        'status': newStatus,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtMs': nowMs,
        'paymentVersion': 2,
        'originalAmount': orig,
      };
      if (newStatus == 'received') {
        duePatch['receivedAt'] = Timestamp.fromMillisecondsSinceEpoch(recvMs);
        duePatch['receivedAtMs'] = recvMs;
      }
      txn.set(dueRef, duePatch, SetOptions(merge: true));
      return rid;
    });
    await syncClientOutstandingForClient(userId, clientId);
    return receiptId;
  }

  Future<String> _appendStandaloneReceipt({
    required String userId,
    required String clientId,
    required String clientName,
    required double receivedAmount,
    required String? noteOut,
    String? paymentMode,
    Object? receiptNumber,
    int? receivedAtMs,
  }) async {
    final ref = _col(userId).doc();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final recvMs = receivedAtMs ?? nowMs;
    final m = <String, dynamic>{
      'type': 'payment',
      'subType': 'payment_received',
      'clientId': clientId,
      'clientName': clientName.trim(),
      'amount': receivedAmount,
      'status': 'received',
      'voided': false,
      'receivedAt': Timestamp.fromMillisecondsSinceEpoch(recvMs),
      'receivedAtMs': recvMs,
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtMs': nowMs,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': nowMs,
    };
    if (noteOut != null && noteOut.isNotEmpty) {
      m['paymentNote'] = noteOut;
      m['note'] = noteOut;
    }
    final mode = paymentMode?.trim();
    if (mode != null && mode.isNotEmpty) {
      m['paymentMode'] = mode;
    }
    if (receiptNumber != null &&
        receiptNumber.toString().trim().isNotEmpty) {
      m['receiptNumber'] = receiptNumber is num
          ? receiptNumber
          : receiptNumber.toString().trim();
    }
    await ref.set(m);
    await syncClientOutstandingForClient(userId, clientId);
    return ref.id;
  }

  /// Backward-compatible alias for [settlePaymentReceived].
  Future<String> recordPaymentReceived({
    required String userId,
    required String clientId,
    required String clientName,
    required double amount,
    String? linkedPaymentId,
    String? note,
  }) async {
    return settlePaymentReceived(
      userId: userId,
      clientId: clientId,
      clientName: clientName,
      receivedAmount: amount,
      linkedPaymentId: linkedPaymentId,
      note: note,
    );
  }

  Future<Map<String, dynamic>?> readDoc(
    String userId,
    String id,
  ) async {
    final s = await _col(userId).doc(id).get();
    return s.exists ? s.data() : null;
  }

  /// Soft-void receipt; recompute linked due; sync client outstanding.
  Future<void> undoReceipt(
    String userId,
    String receiptId, {
    String voidReason = 'user_undo',
  }) async {
    final ref = _col(userId).doc(receiptId);
    final snap = await ref.get();
    if (!snap.exists || snap.data() == null) {
      return;
    }
    final data = snap.data()!;
    if (PaymentSettlementUtils.isVoidedReceiptMap(data)) {
      return;
    }
    final stp = (data['subType'] as String? ?? '').trim().toLowerCase();
    if (stp != 'payment_received') {
      return;
    }
    final linked = (data['linkedPaymentId'] as String? ?? '').trim();
    final clientId = (data['clientId'] as String? ?? '').trim();
    final receivedAmt = (data['amount'] as num?)?.toDouble() ?? 0.0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    await _firestore.runTransaction<void>((txn) async {
      final rSnap = await txn.get(ref);
      if (!rSnap.exists || rSnap.data() == null) {
        return;
      }
      final rd = rSnap.data()!;
      if (PaymentSettlementUtils.isVoidedReceiptMap(rd)) {
        return;
      }
      txn.set(
        ref,
        {
          'voided': true,
          'voidedAt': FieldValue.serverTimestamp(),
          'voidReason': voidReason.trim().isEmpty ? 'user_undo' : voidReason,
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedAtMs': nowMs,
        },
        SetOptions(merge: true),
      );

      if (linked.isEmpty) {
        return;
      }
      final dueRef = _col(userId).doc(linked);
      final dueSnap = await txn.get(dueRef);
      if (!dueSnap.exists || dueSnap.data() == null) {
        return;
      }
      final due = PaymentRecord.fromDoc(dueSnap.id, dueSnap.data()!);
      if (!due.isPaymentDueDocument) {
        return;
      }
      final orig = due.effectiveOriginal;
      final paid = (due.effectivePaid - receivedAmt).clamp(0.0, double.infinity);
      final newRem = (orig - paid).clamp(0.0, double.infinity);
      String newStatus;
      if (newRem <= 1e-9) {
        newStatus = 'received';
      } else if (paid <= 1e-9) {
        newStatus = PaymentSettlementUtils.statusForFullyUnpaidDue(
          dueDateMs: due.dueDateMs,
          nowMs: nowMs,
        );
      } else {
        newStatus = 'partial_pending';
      }
      final rc = ((due.receiptCount ?? 1) - 1).clamp(0, 1 << 30);
      final duePatch = <String, dynamic>{
        'paidAmount': paid,
        'remainingAmount': newRem,
        'receiptCount': rc,
        'status': newStatus,
        'paymentVersion': 2,
        'originalAmount': orig,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtMs': nowMs,
      };
      if (newStatus == 'received') {
        duePatch['receivedAt'] = FieldValue.serverTimestamp();
        duePatch['receivedAtMs'] = nowMs;
      } else {
        duePatch['receivedAt'] = FieldValue.delete();
        duePatch['receivedAtMs'] = FieldValue.delete();
      }
      txn.set(dueRef, duePatch, SetOptions(merge: true));
    });
    if (clientId.isNotEmpty) {
      await syncClientOutstandingForClient(userId, clientId);
    }
  }

  Future<void> deleteById(String userId, String id) async {
    await _col(userId).doc(id).delete();
  }
}
