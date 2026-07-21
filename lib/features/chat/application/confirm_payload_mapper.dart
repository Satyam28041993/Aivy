import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'flow_step_engine.dart';

/// Normalized payload for logging + `users/{uid}/records` ledger.
/// Coerces types so Firestore writes are consistent.
class ConfirmPayloadMapper {
  const ConfirmPayloadMapper._();

  static void debugUserInput(String userMessage) {
    if (kDebugMode) {
      debugPrint('INPUT: $userMessage');
    }
  }

  static void debugDraftBeforeSave(Map<String, dynamic> draft) {
    if (kDebugMode) {
      debugPrint('DRAFT BEFORE SAVE: $draft');
    }
  }

  /// Use on Confirm tap — matches checklist line `PAYLOAD:`.
  static void debugPayloadConfirm(Map<String, dynamic> payload) {
    if (kDebugMode) {
      if (payload.isEmpty) {
        debugPrint('PAYLOAD: <empty> — STOP and check mapping');
      } else {
        debugPrint('PAYLOAD: $payload');
      }
    }
  }

  static void debugPayload(String label, Map<String, dynamic>? payload) {
    if (kDebugMode) {
      if (payload == null || payload.isEmpty) {
        debugPrint('PAYLOAD ($label): <empty or null> — STOP and check mapping');
      } else {
        debugPrint('PAYLOAD ($label): $payload');
      }
    }
  }

  static int? coerceIntAmount(Object? raw) {
    if (raw == null) {
      return null;
    }
    if (raw is int) {
      return raw;
    }
    if (raw is double) {
      return raw.round();
    }
    if (raw is num) {
      return raw.round();
    }
    if (raw is String) {
      return int.tryParse(raw.replaceAll(RegExp(r'[₹,\s]'), ''));
    }
    return null;
  }

  static double? coerceDoubleAmount(Object? raw) {
    if (raw == null) {
      return null;
    }
    if (raw is num) {
      return raw.toDouble();
    }
    if (raw is String) {
      return double.tryParse(raw.replaceAll(RegExp(r'[₹,\s]'), ''));
    }
    return null;
  }

  /// Canonical map for ledger row (also used for debug).
  static Map<String, dynamic> buildLedgerPayload({
    required Map<String, dynamic> confirmMap,
    required String lastActionType,
    String? savedDocId,
    String? sourceCollection,
  }) {
    final fcid = (confirmMap['flowCategoryId'] as String? ?? '').trim();
    final type = (confirmMap['type'] as String? ?? '').trim();
    final subType = (confirmMap['subType'] as String? ?? '').trim();
    final name = (() {
      if (fcid == 'reminder_task') {
        return (confirmMap['clientName'] as String? ?? '').trim();
      }
      return (confirmMap['name'] as String? ?? '').trim();
    })();
    final clientId = (confirmMap['clientId'] as String? ?? '').trim();
    final amt = coerceDoubleAmount(confirmMap['amount']);
    final dr = confirmMap[FlowStepEngine.kDate] ?? confirmMap['date'];
    int? dueMs;
    if (dr is num) {
      dueMs = dr.toInt();
    }
    Timestamp? dueTs;
    if (dueMs != null) {
      dueTs = Timestamp.fromMillisecondsSinceEpoch(dueMs);
    }
    final note = (confirmMap['note'] as String? ?? '').trim();
    final status =
        (confirmMap['status'] as String? ?? 'pending').trim().isEmpty
        ? 'pending'
        : (confirmMap['status'] as String).trim();

    return <String, dynamic>{
      'type': type.isNotEmpty ? type : (fcid.isNotEmpty ? fcid : 'unknown'),
      'subType': subType.isNotEmpty ? subType : fcid,
      'flowCategoryId': fcid,
      'clientId': clientId.isEmpty ? null : clientId,
      'clientName': name.isEmpty ? null : name,
      'amount': amt,
      'amountInt': amt?.round(),
      'dueDate': dueTs,
      'dueDateMs': dueMs,
      'note': note.isEmpty ? null : note,
      'status': status,
      'linkedPaymentId': (confirmMap['linkedPaymentId'] as String? ?? '')
              .trim()
              .isEmpty
          ? null
          : confirmMap['linkedPaymentId'],
      'structuredLegacyId': (confirmMap['structuredLegacyId'] as String? ?? '')
              .trim()
              .isEmpty
          ? null
          : confirmMap['structuredLegacyId'],
      'lastActionType': lastActionType,
      'savedDocId': savedDocId,
      'sourceCollection': sourceCollection,
    }..removeWhere((k, v) => v == null);
  }

  /// Blocks save before routing when required CRM/payment fields are missing.
  static bool hasBlockingValidationErrors(Map<String, dynamic> m) {
    if (missingRequiredClientId(m)) {
      return true;
    }
    final fcid = (m['flowCategoryId'] as String? ?? '').trim();
    if (fcid == 'payment_followup' || fcid == 'followup_payment') {
      final name = (m[FlowStepEngine.kName] as String? ??
              m['name'] as String? ??
              '')
          .trim();
      return name.isEmpty;
    }
    return false;
  }

  /// New payment/follow-up Firestore rows must have [clientId] unless legacy CRM [id] is set.
  static bool missingRequiredClientId(Map<String, dynamic> m) {
    final fcid = (m['flowCategoryId'] as String? ?? '').trim();
    final hasStructuredLegacy =
        (m['id'] as String? ?? '').trim().isNotEmpty ||
        (m['structuredLegacyId'] as String? ?? '').trim().isNotEmpty;
    final hasClient = (m['clientId'] as String? ?? '').trim().isNotEmpty;

    if (fcid == 'payment_due' || fcid == 'payment_received') {
      if (hasStructuredLegacy) {
        return false;
      }
      return !hasClient;
    }
    if (fcid == 'payment_followup' || fcid == 'followup_payment') {
      return !hasClient;
    }
    return false;
  }
}
