import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

/// Activates Firebase App Check for Gemini Live / AI Logic.
///
/// GitHub / sideload APKs cannot use Play Integrity — we use the debug provider
/// so you can register one debug token in Firebase Console (App Check → Debug tokens).
Future<void> activateAivyAppCheck() async {
  try {
    await FirebaseAppCheck.instance.activate(
      // Sideloaded QA APKs: debug provider + registered token in Firebase Console.
      // Switch to [AndroidPlayIntegrityProvider] for Play Store release builds.
      providerAndroid: const AndroidDebugProvider(),
    );
    // Warm token so the debug secret is emitted to logcat on first launch.
    await FirebaseAppCheck.instance.getToken();
    if (kDebugMode) {
      debugPrint(
        '[AppCheck] Activated (debug provider). '
        'If Gemini Live fails, register the debug token from logcat in '
        'Firebase Console → App Check → Manage debug tokens.',
      );
    }
  } catch (e, st) {
    debugPrint('[AppCheck] activate failed (non-fatal): $e\n$st');
  }
}
