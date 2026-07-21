import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../firebase/firebase_session.dart';
import '../firebase/user_document_sync.dart';

/// Holds the signed-in Firebase user and notifies listeners (global auth state).
class AivyAuthController extends ChangeNotifier {
  AivyAuthController() {
    final initial = FirebaseSession.auth.currentUser;
    if (initial != null && initial.isAnonymous) {
      _user = null;
      unawaited(FirebaseSession.signOut());
    } else {
      _user = initial;
    }
    _authSub = FirebaseSession.auth.authStateChanges().listen(_onAuthChanged);
    if (_user != null) {
      unawaited(UserDocumentSync.ensureForGoogleUser(_user!));
    }
  }

  late final StreamSubscription<User?> _authSub;
  User? _user;

  User? get firebaseUser => _user;
  String? get uid => _user?.uid;
  String? get email => _user?.email;
  String? get displayName => _user?.displayName;
  String? get photoUrl => _user?.photoURL;
  bool get isSignedIn => _user != null;

  Future<void> _onAuthChanged(User? next) async {
    await _applyUser(next);
  }

  Future<void> _applyUser(User? next) async {
    if (next != null && next.isAnonymous) {
      if (kDebugMode) {
        debugPrint('[Aivy] Signing out anonymous session (Google sign-in required).');
      }
      await FirebaseSession.signOut();
      _user = null;
      notifyListeners();
      return;
    }

    _user = next;
    notifyListeners();

    if (next != null) {
      try {
        await UserDocumentSync.ensureForGoogleUser(next);
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('[Aivy] user doc sync failed: $e\n$st');
        }
      }
    }
  }

  Future<void> signOut() => FirebaseSession.signOut();

  @override
  void dispose() {
    unawaited(_authSub.cancel());
    super.dispose();
  }
}
