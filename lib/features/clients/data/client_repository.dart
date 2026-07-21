import 'package:cloud_firestore/cloud_firestore.dart';

import '../../structured_actions/utils/name_normalize.dart';
import '../models/client.dart';
import '../models/client_name_resolution.dart';

class ClientRepository {
  ClientRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _col(String userId) {
    return _firestore.collection('users').doc(userId).collection('clients');
  }

  /// Trim + lowercase for matching user input to display names.
  static String normalizeForMatch(String name) => name.trim().toLowerCase();

  /// Names that look like menu text / greetings / chat noise, not real clients.
  /// Used to hide accidental `clients` docs from pickers (Firestore list is raw).
  static bool looksLikeChatNoiseClientName(String raw) {
    final t = raw.trim();
    if (t.length < 2) {
      return true;
    }
    final low = normalizeForMatch(t);
    const singleTokenNoise = <String>{
      'cancel',
      'band',
      'stop',
      'skip',
      'yes',
      'no',
      'haan',
      'nahi',
      'na',
      'ok',
      'okay',
      'theek',
      'confirm',
      'edit',
      'save',
      'list',
      'menu',
      'help',
      'back',
      'next',
      'start',
      'test',
      'hi',
      'hii',
      'hey',
      'hello',
      'namaste',
      'aivy',
      'alvy',
      'alvi',
    };
    final tokens = low.split(RegExp(r'\s+'));
    if (tokens.length == 1 && singleTokenNoise.contains(low)) {
      return true;
    }
    if (tokens.length >= 2) {
      const greet = {'hi', 'hello', 'hey', 'hii', 'namaste'};
      if (greet.contains(tokens.first)) {
        final rest = tokens.sublist(1).join(' ');
        if (rest.contains('aivy') ||
            rest.contains('alvy') ||
            rest == 'there' ||
            rest == 'sir' ||
            rest == 'madam') {
          return true;
        }
      }
    }
    if (low == 'hi aivy' ||
        low == 'hey aivy' ||
        low == 'hello aivy' ||
        low.startsWith('hi alvy')) {
      return true;
    }
    return false;
  }

  /// Subset of [listAll] suitable for "pick a client" UIs.
  Future<List<Client>> listForPicker(String userId) async {
    final all = await listAll(userId);
    return all.where((c) => !looksLikeChatNoiseClientName(c.name)).toList();
  }

  /// 1) Exact normalized name match.
  /// 2) Else unique prefix match (normalized).
  /// 3) Else multiple candidates or none.
  Future<ClientNameResolution> resolveForPaymentName(
    String userId,
    String input,
  ) async {
    final q = input.trim();
    if (q.isEmpty) {
      return ClientNameResolution.none();
    }
    final qn = normalizeForMatch(q);
    final all = await listAll(userId);
    final exact = all
        .where((c) => normalizeForMatch(c.name) == qn)
        .toList(growable: false);
    if (exact.length == 1) {
      return ClientNameResolution.single(exact.single);
    }
    if (exact.length > 1) {
      return ClientNameResolution.disambiguation(exact);
    }
    final prefix = all
        .where((c) => normalizeForMatch(c.name).startsWith(qn))
        .toList(growable: false);
    if (prefix.length == 1) {
      return ClientNameResolution.single(prefix.single);
    }
    if (prefix.length > 1) {
      return ClientNameResolution.disambiguation(prefix);
    }
    return ClientNameResolution.none();
  }

  /// Prefix match on display name (case-insensitive), stable ordering.
  Future<List<Client>> searchClients(String userId, String input) async {
    final q = input.trim();
    if (q.isEmpty) {
      return const [];
    }
    final low = q.toLowerCase();
    final snap = await _col(userId).get();
    final out = <Client>[];
    for (final d in snap.docs) {
      final c = Client.fromDoc(d.id, d.data());
      if (c.name.toLowerCase().startsWith(low)) {
        out.add(c);
      }
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  Future<List<Client>> listAll(String userId) async {
    final snap = await _col(userId).get();
    final out = snap.docs.map((d) => Client.fromDoc(d.id, d.data())).toList();
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  Future<Client?> getById(String userId, String clientId) async {
    final s = await _col(userId).doc(clientId).get();
    if (!s.exists || s.data() == null) {
      return null;
    }
    return Client.fromDoc(s.id, s.data()!);
  }

  Future<Client> createClient(String userId, String name) async {
    final trimmed = name.trim();
    final nl = normalizeName(trimmed);
    final ref = _col(userId).doc();
    final c = Client(
      id: ref.id,
      name: trimmed,
      nameLower: nl,
      outstandingBalance: 0,
    );
    await ref.set(c.toFirestoreCreate());
    return c;
  }

  Future<void> adjustOutstanding(
    String userId,
    String clientId,
    double delta,
  ) async {
    await _col(userId).doc(clientId).set(
      {
        'outstandingBalance': FieldValue.increment(delta),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  /// Authoritative write of outstanding (used after full recomputation from dues).
  Future<void> setOutstandingBalance(
    String userId,
    String clientId,
    double value,
  ) async {
    await _col(userId).doc(clientId).set(
      {
        'outstandingBalance': value,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }
}
