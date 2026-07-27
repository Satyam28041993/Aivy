import 'package:cloud_functions/cloud_functions.dart';

import 'meta_whatsapp_config.dart';
import 'meta_whatsapp_runtime_config.dart';

/// Resolves Meta WhatsApp client configuration without requiring app rebuilds.
///
/// Resolution order:
/// 1. Backend callable (`getMetaWhatsappClientConfig`) — production path
/// 2. Remote Config — optional hook for a future [MetaWhatsappRemoteConfigLoader]
/// 3. dart-define — local development fallback only
class MetaWhatsappConfigResolver {
  MetaWhatsappConfigResolver({
    FirebaseFunctions? functions,
    MetaWhatsappRemoteConfigLoader? remoteConfigLoader,
    Duration cacheTtl = const Duration(minutes: 15),
  }) : _functions =
           functions ?? FirebaseFunctions.instanceFor(region: 'us-central1'),
       _remoteConfigLoader = remoteConfigLoader,
       _cacheTtl = cacheTtl;

  static final MetaWhatsappConfigResolver instance = MetaWhatsappConfigResolver();

  final FirebaseFunctions _functions;
  final MetaWhatsappRemoteConfigLoader? _remoteConfigLoader;
  final Duration _cacheTtl;

  MetaWhatsappRuntimeConfig? _cache;
  DateTime? _cachedAt;

  void clearCache() {
    _cache = null;
    _cachedAt = null;
  }

  Future<MetaWhatsappRuntimeConfig> resolve({bool forceRefresh = false}) async {
    if (!forceRefresh && _cache != null && _cachedAt != null) {
      final age = DateTime.now().difference(_cachedAt!);
      if (age < _cacheTtl && _cache!.isComplete) {
        return _cache!;
      }
    }

    final backend = await _tryBackend();
    if (backend != null && backend.isComplete) {
      _cache = backend;
      _cachedAt = DateTime.now();
      return backend;
    }

    final remote = await _tryRemoteConfig();
    if (remote != null && remote.isComplete) {
      _cache = remote;
      _cachedAt = DateTime.now();
      return remote;
    }

    final fallback = metaWhatsappConfigFromDartDefine();
    if (fallback.isComplete) {
      _cache = fallback;
      _cachedAt = DateTime.now();
      return fallback;
    }

    return MetaWhatsappRuntimeConfig(
      appId: fallback.appId,
      embeddedSignupConfigId: fallback.embeddedSignupConfigId,
      graphApiVersion: fallback.graphApiVersion,
      source: MetaWhatsappConfigSource.unknown,
    );
  }

  Future<bool> isConfigured({bool forceRefresh = false}) async {
    final cfg = await resolve(forceRefresh: forceRefresh);
    return cfg.isComplete;
  }

  Future<MetaWhatsappRuntimeConfig?> _tryBackend() async {
    try {
      final callable = _functions.httpsCallable('getMetaWhatsappClientConfig');
      final result = await callable.call();
      if (result.data is! Map) {
        return null;
      }
      final map = Map<String, dynamic>.from(result.data as Map);
      final cfg = MetaWhatsappRuntimeConfig.fromMap(
        map,
        source: MetaWhatsappConfigSource.backend,
      );
      return cfg.isComplete ? cfg : null;
    } catch (_) {
      return null;
    }
  }

  Future<MetaWhatsappRuntimeConfig?> _tryRemoteConfig() async {
    final loader = _remoteConfigLoader;
    if (loader == null) {
      return null;
    }
    try {
      final cfg = await loader.load();
      return cfg.isComplete ? cfg : null;
    } catch (_) {
      return null;
    }
  }
}

/// Optional Remote Config adapter — wire in when `firebase_remote_config` is added.
abstract class MetaWhatsappRemoteConfigLoader {
  Future<MetaWhatsappRuntimeConfig> load();
}
