import 'meta_embedded_signup_result.dart';

/// Android / iOS placeholder — Embedded Signup will be implemented here later.
bool get metaEmbeddedSignupSupported => false;

Future<MetaEmbeddedSignupResult> launchMetaEmbeddedSignup() async {
  return MetaEmbeddedSignupResult.error(
    'WhatsApp Embedded Signup on mobile is not available yet. '
    'Use the web app to connect your WhatsApp Business number.',
  );
}
