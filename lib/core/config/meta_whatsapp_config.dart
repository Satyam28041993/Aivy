import 'meta_whatsapp_runtime_config.dart';

/// Compile-time fallbacks for local development only.
///
/// Production should resolve [MetaWhatsappRuntimeConfig] from backend or
/// Remote Config via [MetaWhatsappConfigResolver] — not from dart-define alone.
const String kMetaAppIdDartDefine = String.fromEnvironment(
  'META_APP_ID',
  defaultValue: '1138403541782773',
);

const String kMetaEmbeddedSignupConfigIdDartDefine = String.fromEnvironment(
  'META_EMBEDDED_SIGNUP_CONFIG_ID',
);

const String kMetaGraphApiVersionDartDefine = String.fromEnvironment(
  'META_GRAPH_API_VERSION',
  defaultValue: 'v21.0',
);

/// Dev-only snapshot from dart-define. Prefer [MetaWhatsappConfigResolver].
MetaWhatsappRuntimeConfig metaWhatsappConfigFromDartDefine() {
  return MetaWhatsappRuntimeConfig(
    appId: kMetaAppIdDartDefine,
    embeddedSignupConfigId: kMetaEmbeddedSignupConfigIdDartDefine,
    graphApiVersion: kMetaGraphApiVersionDartDefine,
    source: MetaWhatsappConfigSource.dartDefine,
  );
}

/// @deprecated Use [MetaWhatsappConfigResolver.resolve] instead.
bool get isMetaEmbeddedSignupConfigured =>
    metaWhatsappConfigFromDartDefine().isComplete;

/// @deprecated Use resolved config from [MetaWhatsappConfigResolver].
const String kMetaAppId = kMetaAppIdDartDefine;

/// @deprecated Use resolved config from [MetaWhatsappConfigResolver].
const String kMetaEmbeddedSignupConfigId = kMetaEmbeddedSignupConfigIdDartDefine;

/// @deprecated Use resolved config from [MetaWhatsappConfigResolver].
const String kMetaGraphApiVersion = kMetaGraphApiVersionDartDefine;
