import '../../../../core/config/meta_whatsapp_runtime_config.dart';

/// Launch parameters for Facebook Login for Business — Embedded Signup (OAuth code flow).
class MetaEmbeddedSignupLaunchConfig {
  const MetaEmbeddedSignupLaunchConfig({
    required this.configId,
    this.responseType = 'code',
    this.overrideDefaultResponseType = true,
    this.featureType = 'whatsapp_business_app_onboarding',
    this.sessionInfoVersion = '3',
  });

  factory MetaEmbeddedSignupLaunchConfig.fromRuntime(
    MetaWhatsappRuntimeConfig runtime,
  ) {
    return MetaEmbeddedSignupLaunchConfig(
      configId: runtime.embeddedSignupConfigId,
    );
  }

  final String configId;
  final String responseType;
  final bool overrideDefaultResponseType;
  final String featureType;
  final String sessionInfoVersion;

  /// Shape expected by `FB.login` on web (via `dart:js_util.jsify`).
  Map<String, Object> toLoginOptionsMap() {
    return {
      'config_id': configId,
      'response_type': responseType,
      'override_default_response_type': overrideDefaultResponseType,
      'extras': {
        'featureType': featureType,
        'sessionInfoVersion': sessionInfoVersion,
      },
    };
  }
}
