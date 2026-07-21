import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Ensures `users/{uid}/profile`, `sessions`, and `memory` layout exists after Google login.
///
/// Uses merge writes only — safe on every app start; does not replace unrelated fields.
class UserDocumentSync {
  UserDocumentSync._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static Future<void> ensureForGoogleUser(User user) async {
    if (user.isAnonymous) {
      return;
    }
    final uid = user.uid;
    final userRef = _db.collection('users').doc(uid);
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    final profileRef = userRef.collection('profile').doc('main');

    final batch = _db.batch();
    batch.set(
      userRef,
      {
        'lastLoginAt': FieldValue.serverTimestamp(),
        'lastLoginAtMs': nowMs,
        'primaryEmail': user.email,
      },
      SetOptions(merge: true),
    );
    batch.set(
      profileRef,
      {
        'uid': uid,
        'email': user.email,
        'displayName': user.displayName,
        'photoUrl': user.photoURL,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtMs': nowMs,
      },
      SetOptions(merge: true),
    );

    await batch.commit();

    if (kDebugMode) {
      debugPrint('[Aivy] UserDocumentSync merged profile for uid=$uid');
    }
  }
}
