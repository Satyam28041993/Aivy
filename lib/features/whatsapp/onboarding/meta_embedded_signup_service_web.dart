// Web-only: Meta Embedded Signup uses the Facebook JavaScript SDK (`FB.login`).
//
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js_util;

import '../../../../core/config/meta_whatsapp_config_resolver.dart';
import '../../../../core/config/meta_whatsapp_runtime_config.dart';
import 'meta_embedded_signup_launch_config.dart';
import 'meta_embedded_signup_result.dart';

bool get metaEmbeddedSignupSupported => true;

const _finishEvent = 'FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING';
const _cancelEvent = 'CANCEL';

bool _messageListenerRegistered = false;
StreamSubscription<html.MessageEvent>? _messageSub;

Future<void> _ensureFacebookSdkReady(MetaWhatsappRuntimeConfig runtime) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    if (js_util.hasProperty(html.window, 'FB')) {
      final fb = js_util.getProperty(html.window, 'FB');
      final inited = js_util.getProperty(html.window, '_aivyMetaFbInited') == true;
      if (!inited) {
        js_util.callMethod(fb, 'init', [
          js_util.jsify({
            'appId': runtime.appId,
            'cookie': true,
            'xfbml': false,
            'version': runtime.graphApiVersion,
          }),
        ]);
        js_util.setProperty(html.window, '_aivyMetaFbInited', true);
      }
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  throw StateError('Facebook JavaScript SDK did not load in time.');
}

bool _isTrustedFacebookOrigin(String origin) {
  if (origin.isEmpty) {
    return false;
  }
  final uri = Uri.tryParse(origin);
  if (uri == null || uri.scheme != 'https') {
    return false;
  }
  final host = uri.host.toLowerCase();
  return host == 'facebook.com' || host.endsWith('.facebook.com');
}

Map<String, dynamic>? _parseEmbeddedSignupMessage(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return null;
    }
    final map = Map<String, dynamic>.from(decoded);
    if ('${map['type'] ?? ''}'.trim() != 'WA_EMBEDDED_SIGNUP') {
      return null;
    }
    return map;
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? _coerceEventData(Object? raw) {
  if (raw == null) {
    return null;
  }
  if (raw is Map) {
    return Map<String, dynamic>.from(raw);
  }
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      return null;
    }
  }
  return null;
}

String? _readOAuthCode(Object? response) {
  if (response == null || !js_util.hasProperty(response, 'authResponse')) {
    return null;
  }
  final auth = js_util.getProperty(response, 'authResponse');
  if (auth == null) {
    return null;
  }
  final code = js_util.getProperty(auth, 'code');
  if (code == null) {
    return null;
  }
  final s = '$code'.trim();
  return s.isEmpty ? null : s;
}

bool _loginWasCancelled(Object? response) {
  if (response == null) {
    return true;
  }
  final status = js_util.getProperty(response, 'status');
  return '$status'.trim() == 'unknown';
}

void _registerMessageListener(void Function(Map<String, dynamic> payload) onEvent) {
  if (_messageListenerRegistered) {
    return;
  }
  _messageListenerRegistered = true;
  _messageSub = html.window.onMessage.listen((event) {
    if (!_isTrustedFacebookOrigin(event.origin)) {
      return;
    }
    final payload = _parseEmbeddedSignupMessage(event.data);
    if (payload != null) {
      onEvent(payload);
    }
  });
}

Future<void> _disposeMessageListener() async {
  await _messageSub?.cancel();
  _messageSub = null;
  _messageListenerRegistered = false;
}

Future<MetaEmbeddedSignupResult> launchMetaEmbeddedSignup() async {
  final runtime = await MetaWhatsappConfigResolver.instance.resolve();
  if (!runtime.isComplete) {
    return MetaEmbeddedSignupResult.error(
      'Meta Embedded Signup is not configured. '
      'Ask an admin to set app_config/meta_whatsapp or use local dart-defines.',
    );
  }

  try {
    await _ensureFacebookSdkReady(runtime);
  } catch (e) {
    return MetaEmbeddedSignupResult.error(
      'Facebook SDK unavailable: $e',
    );
  }

  final fb = js_util.getProperty(html.window, 'FB');
  final completer = Completer<MetaEmbeddedSignupResult>();
  String? oauthCode;
  String? finishEventName;
  Map<String, dynamic>? finishEventData;

  void tryComplete() {
    if (completer.isCompleted) {
      return;
    }
    if (oauthCode != null || finishEventName == _finishEvent) {
      final href = html.window.location.href;
      final hashIndex = href.indexOf('#');
      final currentRedirectUri = hashIndex != -1 ? href.substring(0, hashIndex) : href;

      completer.complete(
        MetaEmbeddedSignupResult.completed(
          oauthCode: oauthCode,
          redirectUri: currentRedirectUri,
          eventName: finishEventName,
          eventData: finishEventData,
        ),
      );
      return;
    }
    if (finishEventName == _cancelEvent) {
      completer.complete(MetaEmbeddedSignupResult.cancelled());
    }
  }

  _registerMessageListener((payload) {
    final eventName = '${payload['event'] ?? ''}'.trim();
    if (eventName.isEmpty) {
      return;
    }
    finishEventName = eventName;
    finishEventData = _coerceEventData(payload['data']);
    if (eventName == _cancelEvent) {
      if (!completer.isCompleted) {
        completer.complete(MetaEmbeddedSignupResult.cancelled());
      }
      return;
    }
    if (eventName == _finishEvent) {
      tryComplete();
    }
  });

  final launchConfig = MetaEmbeddedSignupLaunchConfig.fromRuntime(runtime);
  js_util.callMethod(fb, 'login', [
    js_util.allowInterop((Object? response) {
      oauthCode = _readOAuthCode(response);
      if (_loginWasCancelled(response) && oauthCode == null) {
        if (!completer.isCompleted) {
          completer.complete(MetaEmbeddedSignupResult.cancelled());
        }
        return;
      }
      tryComplete();
    }),
    js_util.jsify(launchConfig.toLoginOptionsMap()),
  ]);

  try {
    return await completer.future.timeout(
      const Duration(minutes: 10),
      onTimeout: () => MetaEmbeddedSignupResult.error(
        'Embedded Signup timed out waiting for completion.',
      ),
    );
  } finally {
    await _disposeMessageListener();
  }
}
