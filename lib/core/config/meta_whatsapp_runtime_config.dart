/// Resolved Meta WhatsApp client configuration used to launch Embedded Signup.
class MetaWhatsappRuntimeConfig {
  const MetaWhatsappRuntimeConfig({
    required this.appId,
    required this.embeddedSignupConfigId,
    this.graphApiVersion = 'v21.0',
    this.source = MetaWhatsappConfigSource.unknown,
  });

  final String appId;
  final String embeddedSignupConfigId;
  final String graphApiVersion;
  final MetaWhatsappConfigSource source;

  bool get isComplete =>
      appId.trim().isNotEmpty && embeddedSignupConfigId.trim().isNotEmpty;

  factory MetaWhatsappRuntimeConfig.fromMap(
    Map<String, dynamic> map, {
    MetaWhatsappConfigSource source = MetaWhatsappConfigSource.backend,
  }) {
    return MetaWhatsappRuntimeConfig(
      appId: '${map['appId'] ?? ''}'.trim(),
      embeddedSignupConfigId:
          '${map['embeddedSignupConfigId'] ?? map['configId'] ?? ''}'.trim(),
      graphApiVersion:
          '${map['graphApiVersion'] ?? 'v21.0'}'.trim().isEmpty
              ? 'v21.0'
              : '${map['graphApiVersion'] ?? 'v21.0'}'.trim(),
      source: source,
    );
  }
}

enum MetaWhatsappConfigSource {
  backend,
  remoteConfig,
  dartDefine,
  unknown,
}
