import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/config/meta_whatsapp_config_resolver.dart';
import '../../../core/config/meta_whatsapp_runtime_config.dart';
import '../onboarding/meta_embedded_signup_result.dart';

/// Connection metadata stored in Firestore (no business token).
class WhatsappConnectionMetadata {
  const WhatsappConnectionMetadata({
    required this.wabaId,
    required this.phoneNumberId,
    this.displayPhoneNumber = '',
    this.connectionStatus = 'connected',
    this.historySyncStatus = 'pending',
    this.tokenSecretRef = '',
  });

  final String wabaId;
  final String phoneNumberId;
  final String displayPhoneNumber;
  final String connectionStatus;
  final String historySyncStatus;
  final String tokenSecretRef;

  factory WhatsappConnectionMetadata.fromMap(Map<String, dynamic> map) {
    return WhatsappConnectionMetadata(
      wabaId: '${map['wabaId'] ?? ''}'.trim(),
      phoneNumberId: '${map['phoneNumberId'] ?? ''}'.trim(),
      displayPhoneNumber: '${map['displayPhoneNumber'] ?? ''}'.trim(),
      connectionStatus: '${map['connectionStatus'] ?? 'connected'}'.trim(),
      historySyncStatus: '${map['historySyncStatus'] ?? 'pending'}'.trim(),
      tokenSecretRef: '${map['tokenSecretRef'] ?? ''}'.trim(),
    );
  }
}

/// Phase 2 onboarding backend integration — isolated from legacy Cloud API config.
class WhatsappOnboardingRepository {
  WhatsappOnboardingRepository({
    FirebaseFunctions? functions,
    MetaWhatsappConfigResolver? configResolver,
  }) : _functions =
           functions ?? FirebaseFunctions.instanceFor(region: 'us-central1'),
       _configResolver = configResolver ?? MetaWhatsappConfigResolver.instance;

  final FirebaseFunctions _functions;
  final MetaWhatsappConfigResolver _configResolver;

  Future<MetaWhatsappRuntimeConfig> fetchClientConfig({bool forceRefresh = false}) {
    return _configResolver.resolve(forceRefresh: forceRefresh);
  }

  Future<WhatsappConnectionMetadata> completeEmbeddedSignup({
    required String code,
    String? redirectUri,
    String? wabaId,
    String? phoneNumberId,
    String? displayPhoneNumber,
  }) async {
    final callable = _functions.httpsCallable('completeWhatsappEmbeddedSignup');
    final payload = <String, dynamic>{'code': code.trim()};
    if (redirectUri != null && redirectUri.trim().isNotEmpty) {
      payload['redirectUri'] = redirectUri.trim();
    }
    final waba = wabaId?.trim();
    final phone = phoneNumberId?.trim();
    final display = displayPhoneNumber?.trim();
    if (waba != null && waba.isNotEmpty) {
      payload['wabaId'] = waba;
    }
    if (phone != null && phone.isNotEmpty) {
      payload['phoneNumberId'] = phone;
    }
    if (display != null && display.isNotEmpty) {
      payload['displayPhoneNumber'] = display;
    }

    try {
      final result = await callable.call(payload);
      if (result.data is! Map) {
        throw Exception('Unexpected onboarding response.');
      }
      return WhatsappConnectionMetadata.fromMap(
        Map<String, dynamic>.from(result.data as Map),
      );
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? e.code);
    }
  }

  /// Runs Embedded Signup then exchanges the OAuth code on the backend.
  Future<({MetaEmbeddedSignupResult launch, WhatsappConnectionMetadata? connection})>
  launchAndComplete(Future<MetaEmbeddedSignupResult> Function() launchSignup) async {
    final launch = await launchSignup();
    if (!launch.isSuccess || (launch.oauthCode ?? '').isEmpty) {
      return (launch: launch, connection: null);
    }

    final eventData = launch.eventData ?? const <String, dynamic>{};
    final connection = await completeEmbeddedSignup(
      code: launch.oauthCode!,
      redirectUri: launch.redirectUri,
      wabaId: _readEventField(eventData, ['waba_id', 'wabaId']),
      phoneNumberId: _readEventField(eventData, [
        'phone_number_id',
        'phoneNumberId',
      ]),
      displayPhoneNumber: _readEventField(eventData, [
        'display_phone_number',
        'displayPhoneNumber',
      ]),
    );
    return (launch: launch, connection: connection);
  }

  String? _readEventField(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = '${data[key] ?? ''}'.trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }
}
