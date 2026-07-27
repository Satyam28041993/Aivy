enum MetaEmbeddedSignupStatus {
  completed,
  cancelled,
  error,
}

/// In-memory outcome from a single Embedded Signup session.
///
/// Phase 1 does not persist any of these values.
class MetaEmbeddedSignupResult {
  const MetaEmbeddedSignupResult({
    required this.status,
    this.oauthCode,
    this.redirectUri,
    this.eventName,
    this.eventData,
    this.errorMessage,
  });

  final MetaEmbeddedSignupStatus status;
  final String? oauthCode;
  final String? redirectUri;
  final String? eventName;
  final Map<String, dynamic>? eventData;
  final String? errorMessage;

  bool get isSuccess => status == MetaEmbeddedSignupStatus.completed;

  factory MetaEmbeddedSignupResult.cancelled({String? message}) {
    return MetaEmbeddedSignupResult(
      status: MetaEmbeddedSignupStatus.cancelled,
      errorMessage: message,
    );
  }

  factory MetaEmbeddedSignupResult.error(String message) {
    return MetaEmbeddedSignupResult(
      status: MetaEmbeddedSignupStatus.error,
      errorMessage: message,
    );
  }

  factory MetaEmbeddedSignupResult.completed({
    String? oauthCode,
    String? redirectUri,
    String? eventName,
    Map<String, dynamic>? eventData,
  }) {
    return MetaEmbeddedSignupResult(
      status: MetaEmbeddedSignupStatus.completed,
      oauthCode: oauthCode,
      redirectUri: redirectUri,
      eventName: eventName,
      eventData: eventData,
    );
  }
}
