import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

/// reCAPTCHA v3 site key for the web build, supplied at build time:
/// `flutter build web --dart-define=AIVY_RECAPTCHA_SITE_KEY=...`
///
/// Register it in Firebase Console → App Check → the web app.
const _webRecaptchaSiteKey = String.fromEnvironment('AIVY_RECAPTCHA_SITE_KEY');

/// What activation actually did, shown in the Live error banner.
///
/// Every failure mode here looks identical from the outside -- the socket just
/// closes with 1008 -- so without this it is impossible to tell a missing site
/// key from a key reCAPTCHA refused to mint a token for.
String aivyAppCheckStatus = 'not started';

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
        aivyAppCheckStatus = 'web: no site key in build';
        debugPrint(
          '[AppCheck] Web: no site key, skipping activation. '
          'Pass --dart-define=AIVY_RECAPTCHA_SITE_KEY=... to enable it.',
        );
        return;
      }
      final keyTail =
          _webRecaptchaSiteKey.substring(_webRecaptchaSiteKey.length - 6);
      await FirebaseAppCheck.instance.activate(
        providerWeb: ReCaptchaV3Provider(_webRecaptchaSiteKey),
      );
      final token = await FirebaseAppCheck.instance.getToken();
      aivyAppCheckStatus = (token == null || token.isEmpty)
          ? 'web: reCAPTCHA gave no token (key ...$keyTail)'
          : 'web: token ok (key ...$keyTail)';
      debugPrint('[AppCheck] $aivyAppCheckStatus');
      return;
    }

    await FirebaseAppCheck.instance.activate(
      // Sideloaded QA APKs: debug provider + registered token in Firebase Console.
      // Switch to [AndroidPlayIntegrityProvider] for Play Store release builds.
      providerAndroid: const AndroidDebugProvider(),
    );
    // Warm token so the debug secret is emitted to logcat on first launch.
    final token = await FirebaseAppCheck.instance.getToken();
    aivyAppCheckStatus = (token == null || token.isEmpty)
        ? 'android: debug provider gave no token'
        : 'android: debug token ok (register it in Firebase Console)';
    if (kDebugMode) {
      debugPrint(
        '[AppCheck] Activated (debug provider). '
        'If Gemini Live fails, register the debug token from logcat in '
        'Firebase Console → App Check → Manage debug tokens.',
      );
    }
  } catch (e, st) {
    aivyAppCheckStatus = 'failed: $e';
    debugPrint('[AppCheck] activate failed (non-fatal): $e\n$st');
  }
}
