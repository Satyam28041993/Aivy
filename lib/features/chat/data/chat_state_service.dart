import 'package:cloud_firestore/cloud_firestore.dart';

import 'chat_flow_state.dart';

/// Read/write `users/{uid}/meta/chat_state` flow fields.
class ChatStateService {
  ChatStateService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> _ref(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('meta')
        .doc('chat_state');
  }

  /// Current flow snapshot (ignores other keys like [activeChatId]).
  Future<ChatFlowState> getState(String userId) async {
    final snap = await _ref(userId).get();
    return ChatFlowState.fromFirestore(snap.data());
  }

  /// Merges flow fields; does not remove unrelated keys like [activeChatId].
  Future<void> updateState(String userId, ChatFlowState state) async {
    final out = <String, dynamic>{};
    for (final e in state.toPatchForMerge().entries) {
      if (e.value == null) {
        out[e.key] = FieldValue.delete();
      } else {
        out[e.key] = e.value!;
      }
    }
    await _ref(userId).set(out, SetOptions(merge: true));
  }

  /// Ends in-chat confirm (awaiting_chat_confirm); clears pending draft / draft map.
  /// Same persisted fields as [clearState] for flow UX — frees user from stuck confirm.
  Future<void> clearConfirmState(String userId) async {
    await clearState(userId);
  }

  /// Clears only controlled-flow keys (keeps [lastActionId] / [lastActionType] for undo).
  Future<void> clearState(String userId) async {
    await _ref(userId).set(
      {
        'currentCategory': FieldValue.delete(),
        'currentSubcategory': FieldValue.delete(),
        'flowCategoryId': FieldValue.delete(),
        'pendingAction': FieldValue.delete(),
        'pendingData': FieldValue.delete(),
        'fieldStep': FieldValue.delete(),
        'stepIndex': FieldValue.delete(),
        'pendingSelection': FieldValue.delete(),
        'selectionType': FieldValue.delete(),
        'selectionList': FieldValue.delete(),
      },
      SetOptions(merge: true),
    );
  }

  /// After a successful save — enables undo (Phase 5).
  Future<void> setLastActionRecord(
    String userId, {
    required String lastActionId,
    required String lastActionType,
  }) async {
    await _ref(userId).set(
      {
        'lastActionId': lastActionId,
        'lastActionType': lastActionType,
      },
      SetOptions(merge: true),
    );
  }

  /// Clears undo pointer after [undo] or when superseded.
  Future<void> clearLastActionRecord(String userId) async {
    await _ref(userId).set(
      {
        'lastActionId': FieldValue.delete(),
        'lastActionType': FieldValue.delete(),
      },
      SetOptions(merge: true),
    );
  }

  /// Phase 6: context memory — merge only; [ChatFlowState.toPatchForMerge] omits null
  /// [lastEntity] so routine updates do not clear it.
  Future<void> setLastEntity(
    String userId, {
    required String name,
    required String type,
  }) async {
    final n = name.trim();
    if (n.isEmpty) {
      return;
    }
    await _ref(userId).set(
      {
        'lastEntity': {
          'name': n,
          'type': type,
        },
      },
      SetOptions(merge: true),
    );
  }
}
