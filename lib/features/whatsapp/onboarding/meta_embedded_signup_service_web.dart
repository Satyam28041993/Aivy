// Web-only: Meta Embedded Signup uses the Facebook JavaScript SDK (`FB.login`).
//
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
// `flutter analyze` resolves this file against a non-web platform, where
// dart:js_util does not exist, so it reports the URI as missing. The web build
// compiles it fine — this file is only ever reached through a conditional
// import from `meta_embedded_signup_service.dart`.
// ignore: uri_does_not_exist
import 'dart:js_util' as js_util;

import '../../../../core/config/meta_whatsapp_config_resolver.dart';
import '../../../../core/config/meta_whatsapp_runtime_config.dart';
import 'meta_embedded_signup_launch_config.dart';
import 'meta_embedded_signup_result.dart';

bool get metaEmbeddedSignupSupported => true;

// Meta emits a different FINISH event per flow: coexistence onboarding, a plain
// new-WABA signup, and a WABA-only signup. Treat them all as completion.
const _finishEvents = <String>{
  'FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING',
  'FINISH',
  'FINISH_ONLY_WABA',
};
const _cancelEvent = 'CANCEL';

/// How long to keep waiting for the popup's FINISH message after `FB.login`
/// has already handed us the OAuth code. If it never arrives we still continue:
/// the backend resolves the WABA and phone number from the token.
const _finishGrace = Duration(seconds: 3);

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
  if (js_util.hasProperty(auth, 'code')) {
    final code = js_util.getProperty(auth, 'code');
    if (code != null && '$code'.trim().isNotEmpty) {
      return '$code'.trim();
    }
  }
  if (js_util.hasProperty(auth, 'accessToken')) {
    final token = js_util.getProperty(auth, 'accessToken');
    if (token != null && '$token'.trim().isNotEmpty) {
      return '$token'.trim();
    }
  }
  return null;
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

  Timer? graceTimer;

  void finishNow() {
    if (completer.isCompleted) {
      return;
    }
    graceTimer?.cancel();
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
  }

  void tryComplete() {
    if (completer.isCompleted) {
      return;
    }
    if (finishEventName == _cancelEvent) {
      graceTimer?.cancel();
      completer.complete(MetaEmbeddedSignupResult.cancelled());
      return;
    }
    if (oauthCode == null) {
      // The popup finished but FB.login has not called back yet; wait for it.
      return;
    }
    if (_finishEvents.contains(finishEventName)) {
      finishNow();
      return;
    }
    // We have the code but no FINISH message yet. Give the popup a moment —
    // some flows (notably reconnects) never send one — then proceed anyway.
    graceTimer ??= Timer(_finishGrace, finishNow);
  }

  _registerMessageListener((payload) {
    html.window.console.log('[aivy-es] message ${jsonEncode(payload)}');
    final eventName = '${payload['event'] ?? ''}'.trim();
    if (eventName.isEmpty) {
      return;
    }
    // Meta emits one message per step; never let a later step overwrite the
    // FINISH payload that carries waba_id / phone_number_id.
    if (_finishEvents.contains(finishEventName)) {
      return;
    }
    finishEventName = eventName;
    finishEventData = _coerceEventData(payload['data']);
    tryComplete();
  });

  // `?es=plain` runs Embedded Signup without the coexistence featureType, which
  // is what we A/B against when the code exchange keeps failing with 36008.
  final esMode = Uri.base.queryParameters['es']?.trim().toLowerCase();
  final launchConfig = MetaEmbeddedSignupLaunchConfig.fromRuntime(
    runtime,
    featureTypeOverride: esMode == 'plain' ? '' : null,
  );
  html.window.console.log(
    '[aivy-es] launching with ${jsonEncode(launchConfig.toLoginOptionsMap())}',
  );
  js_util.callMethod(fb, 'login', [
    js_util.allowInterop((Object? response) {
      html.window.console.log('[aivy-es] FB.login response');
      html.window.console.log(response);
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
    graceTimer?.cancel();
    await _disposeMessageListener();
  }
}
