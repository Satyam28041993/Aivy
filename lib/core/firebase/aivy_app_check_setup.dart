import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

/// reCAPTCHA v3 site key for the web build, supplied at build time:
/// `flutter build web --dart-define=AIVY_RECAPTCHA_SITE_KEY=...`
///
/// Register it in Firebase Console → App Check → the web app.
const _webRecaptchaSiteKey = String.fromEnvironment('AIVY_RECAPTCHA_SITE_KEY');

/// Activates Firebase App Check for Gemini Live / AI Logic.
///
/// GitHub / sideload APKs cannot use Play Integrity — we use the debug provider
/// so you can register one debug token in Firebase Console (App Check → Debug tokens).
Future<void> activateAivyAppCheck() async {
  try {
    if (kIsWeb) {
      // Activating with no web provider still attaches an App Check header,
      // and the backend rejects that token outright — the Live socket closes
      // with 1008 "App Check token is invalid". Sending nothing at all is
      // accepted while enforcement is in monitoring mode, so stay out of the
      // way until a real site key exists.
      if (_webRecaptchaSiteKey.isEmpty) {
        debugPrint(
          '[AppCheck] Web: no site key, skipping activation. '
          'Pass --dart-define=AIVY_RECAPTCHA_SITE_KEY=... to enable it.',
        );
        return;
      }
      await FirebaseAppCheck.instance.activate(
        providerWeb: ReCaptchaV3Provider(_webRecaptchaSiteKey),
      );
      await FirebaseAppCheck.instance.getToken();
      return;
    }

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
