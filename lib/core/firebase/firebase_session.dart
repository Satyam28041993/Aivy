import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../config/aivy_identity.dart';
import '../google/aivy_google_scopes.dart';

class FirebaseSession {
  FirebaseSession._();

  static final FirebaseAuth auth = FirebaseAuth.instance;

  static final FirebaseFunctions functions = FirebaseFunctions.instanceFor(
    region: 'us-central1',
  );

  static GoogleSignIn? _googleSignInInstance;

  static GoogleSignIn _googleSignIn() {
    return _googleSignInInstance ??= _buildGoogleSignIn();
  }

  static GoogleSignIn _buildGoogleSignIn() {
    final webId = kWebGoogleClientId.trim();
    if (kIsWeb && webId.isNotEmpty) {
      return GoogleSignIn(
        scopes: const <String>['email', 'profile'],
        clientId: webId,
      );
    }
    return GoogleSignIn(
      scopes: const <String>['email', 'profile'],
    );
  }

  static String describeAuthFailure(Object error) {
    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'network-request-failed':
          return 'Network error. Check your connection and try again.';
        case 'user-disabled':
          return 'This account has been disabled.';
        case 'invalid-credential':
        case 'user-not-found':
          return 'Sign-in failed. Please try again.';
        case 'account-exists-with-different-credential':
          return 'An account already exists with a different sign-in method.';
        case 'popup-closed-by-user':
        case 'cancelled-popup-request':
          return 'Sign-in was cancelled.';
        case 'popup-blocked':
          return 'Pop-up was blocked. Allow pop-ups for this site and try again.';
        default:
          break;
      }
      final msg = error.message?.trim();
      if (msg != null && msg.isNotEmpty) {
        return msg;
      }
      return 'Sign-in failed (${error.code}).';
    }
    if (error is FirebaseException) {
      if (error.code == 'unavailable' || error.code == 'deadline-exceeded') {
        return 'Service temporarily unavailable. Check your network and try again.';
      }
    }
    if (error is SocketException) {
      return 'No internet connection. Try again when you are online.';
    }
    final s = error.toString();
    if (s.contains('Google sign-in was cancelled')) {
      return 'Sign-in was cancelled.';
    }
    return 'Something went wrong. Please try again.';
  }

  /// Google account — Firebase assigns a stable [User.uid] for this provider
  /// (same Google account ⇒ same uid on every device).
  static Future<User> signInWithGoogle() async {
    if (kIsWeb) {
      return _signInWithGoogleWeb();
    }

    final google = _googleSignIn();
    try {
      final account = await google.signIn();
      if (account == null) {
        throw StateError('Google sign-in was cancelled.');
      }
      final ga = await account.authentication;
      final oauth = GoogleAuthProvider.credential(
        idToken: ga.idToken,
        accessToken: ga.accessToken,
      );
      final cred = await auth.signInWithCredential(oauth);
      final user = cred.user;
      if (user == null) {
        throw StateError('Google sign-in did not return a user.');
      }
      if (user.isAnonymous) {
        throw StateError('Anonymous sessions are not allowed.');
      }
      final idToken = await user.getIdToken(true);
      if (idToken == null || idToken.trim().isEmpty) {
        throw StateError('Unable to get auth token after Google sign-in.');
      }
      if (kDebugMode) {
        debugPrint('[Aivy] Google auth uid=${user.uid} email=${user.email}');
      }
      return user;
    } catch (e, st) {
      try {
        await google.signOut();
      } catch (_) {}
      if (e is FirebaseAuthException) {
        Error.throwWithStackTrace(e, st);
      }
      rethrow;
    }
  }

  /// Web uses Firebase Auth’s Google popup, which only needs your Firebase
  /// config. The [google_sign_in] web plugin also requires a separate “Web
  /// client” OAuth ID (meta tag or [kWebGoogleClientId]); we avoid that here.
  static Future<User> _signInWithGoogleWeb() async {
    try {
      final cred = await auth.signInWithPopup(GoogleAuthProvider());
      final user = cred.user;
      if (user == null) {
        throw StateError('Google sign-in did not return a user.');
      }
      if (user.isAnonymous) {
        throw StateError('Anonymous sessions are not allowed.');
      }
      final idToken = await user.getIdToken(true);
      if (idToken == null || idToken.trim().isEmpty) {
        throw StateError('Unable to get auth token after Google sign-in.');
      }
      if (kDebugMode) {
        debugPrint('[Aivy] Google auth (web) uid=${user.uid} email=${user.email}');
      }
      return user;
    } catch (e, st) {
      if (e is FirebaseAuthException) {
        Error.throwWithStackTrace(e, st);
      }
      rethrow;
    }
  }

  /// Some Android [GoogleSignIn] builds throw [UnimplementedError] for
  /// [GoogleSignIn.canAccessScopes]; fall back to [requestScopes] only.
  static Future<bool> _workspaceScopesGranted(GoogleSignIn google) async {
    final scopes = AivyGoogleScopes.workspaceApiScopes;
    try {
      if (await google.canAccessScopes(scopes)) {
        return true;
      }
    } on UnimplementedError {
      if (kDebugMode) {
        debugPrint(
          '[Aivy] canAccessScopes unavailable — using requestScopes only.',
        );
      }
    }
    return google.requestScopes(scopes);
  }

  /// Android / iOS: requests Contacts, Calendar, Sheets, and Gmail send scopes.
  /// Returns false on web (use Android for these APIs with the current stack).
  static Future<bool> ensureWorkspaceScopes() async {
    if (kIsWeb) {
      return false;
    }
    final google = _googleSignIn();
    GoogleSignInAccount? acct = google.currentUser;
    acct ??= await google.signInSilently(suppressErrors: true);
    acct ??= await google.signIn();
    if (acct == null) {
      return false;
    }
    return _workspaceScopesGranted(google);
  }

  /// Bearer headers for People, Calendar, Sheets, Gmail REST calls.
  static Future<Map<String, String>> googleWorkspaceAuthHeaders() async {
    if (kIsWeb) {
      throw UnsupportedError(
        'Google workspace REST APIs require the Android app with device Google sign-in.',
      );
    }
    final google = _googleSignIn();
    GoogleSignInAccount? acct = google.currentUser;
    acct ??= await google.signInSilently(suppressErrors: true);
    if (acct == null) {
      throw StateError('Google account not active on device. Sign in again.');
    }
    final ok = await _workspaceScopesGranted(google);
    if (!ok) {
      throw StateError(
        'Allow Google permissions: open More → Allow Google extras.',
      );
    }
    final after = google.currentUser ?? acct;
    return after.authHeaders;
  }

  static Future<void> signOut() async {
    if (kIsWeb) {
      await auth.signOut();
    } else {
      final google = _googleSignIn();
      await Future.wait<void>(<Future<void>>[
        auth.signOut(),
        google.signOut(),
      ]);
    }
    if (kDebugMode) {
      debugPrint('[Aivy] Signed out of Firebase and Google.');
    }
  }

  /// Requires an existing Google (non-anonymous) session.
  static Future<User> ensureAuthenticatedUser({
    bool forceTokenRefresh = true,
  }) async {
    final user = auth.currentUser;
    if (user == null) {
      throw StateError('Not signed in. Please continue with Google.');
    }
    if (user.isAnonymous) {
      throw StateError('Anonymous sessions are disabled. Please sign in with Google.');
    }

    final idToken = await user.getIdToken(forceTokenRefresh);
    if (idToken == null || idToken.trim().isEmpty) {
      throw StateError('Unable to get auth token for callable request.');
    }

    if (kDebugMode) {
      debugPrint(
        '[Aivy] Auth ready uid=${user.uid}, tokenPresent=${idToken.isNotEmpty}',
      );
    }

    return user;
  }
}
