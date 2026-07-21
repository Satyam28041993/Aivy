import 'client.dart';

/// Result of resolving a typed client name against `users/{uid}/clients`.
class ClientNameResolution {
  ClientNameResolution.single(this.client)
      : candidates = const [],
        isNone = false;

  ClientNameResolution.disambiguation(this.candidates)
      : client = null,
        isNone = false;

  ClientNameResolution.none()
      : client = null,
        candidates = const [],
        isNone = true;

  final Client? client;
  final List<Client> candidates;
  final bool isNone;

  bool get hasSingle => client != null;

  bool get needsDisambiguation =>
      client == null && candidates.length > 1;

  bool get needsCreateConfirmation =>
      client == null && candidates.isEmpty && isNone;
}
