import 'meta_embedded_signup_result.dart';

bool get metaEmbeddedSignupSupported => false;

Future<MetaEmbeddedSignupResult> launchMetaEmbeddedSignup() async {
  return MetaEmbeddedSignupResult.error(
    'WhatsApp Embedded Signup is only available on web.',
  );
}
