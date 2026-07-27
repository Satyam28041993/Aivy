import 'meta_embedded_signup_result.dart';
import 'meta_embedded_signup_service_stub.dart'
    if (dart.library.io) 'meta_embedded_signup_service_mobile.dart'
    if (dart.library.html) 'meta_embedded_signup_service_web.dart' as impl;

/// Platform launcher for Meta WhatsApp Embedded Signup (Tech Provider coexistence).
///
/// Implementations:
/// - [meta_embedded_signup_service_web.dart] — Facebook JS SDK (web)
/// - [meta_embedded_signup_service_mobile.dart] — future Android/iOS
/// - [meta_embedded_signup_service_stub.dart] — unsupported platforms
class MetaEmbeddedSignupService {
  MetaEmbeddedSignupService._();

  static final MetaEmbeddedSignupService instance = MetaEmbeddedSignupService._();

  bool get isSupported => impl.metaEmbeddedSignupSupported;

  Future<MetaEmbeddedSignupResult> launch() => impl.launchMetaEmbeddedSignup();
}
