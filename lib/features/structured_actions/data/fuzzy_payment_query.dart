import 'dart:math' as math;

import '../models/structured_action.dart';
import '../utils/name_normalize.dart';

/// One client (by [nameLower]) and their open payment rows.
class FuzzyNameGroup {
  const FuzzyNameGroup({
    required this.nameLower,
    required this.displayName,
    required this.actions,
  });

  final String nameLower;
  final String displayName;
  final List<StructuredAction> actions;
}

/// Result of fuzzy open-payment lookup (Phase 6).
class FuzzyPaymentQueryResult {
  const FuzzyPaymentQueryResult._({
    required this.actions,
    this.nameGroups,
    this.aliasLearnNameLower,
    this.aliasLearnToken,
  });

  /// Single client (or post name-pick): use [actions] directly.
  final List<StructuredAction> actions;

  /// Multiple possible clients — user must pick one (by number or name).
  final List<FuzzyNameGroup>? nameGroups;

  /// If match was by startsWith/contains, learn [aliasLearnToken] for this [nameLower].
  final String? aliasLearnNameLower;
  final String? aliasLearnToken;

  bool get needsNamePick => nameGroups != null && nameGroups!.length > 1;
  bool get hasAliasToLearn {
    final t = aliasLearnToken;
    return aliasLearnNameLower != null && t != null && t.isNotEmpty;
  }

  factory FuzzyPaymentQueryResult.empty() =>
      const FuzzyPaymentQueryResult._(actions: []);

  factory FuzzyPaymentQueryResult.nameDisambig(List<FuzzyNameGroup> groups) =>
      FuzzyPaymentQueryResult._(actions: [], nameGroups: groups);
}

bool _isOpenForQuery(StructuredAction a) {
  final s = a.status.toLowerCase();
  return s != 'completed' && s != 'reverted';
}

int _rankForQuery(String n, String key, List<String> aliasNorms) {
  if (n.isEmpty || key.isEmpty) {
    return 0;
  }
  if (n == key) {
    return 100;
  }
  for (final al in aliasNorms) {
    if (n == al) {
      return 95;
    }
  }
  if (key.startsWith(n) && n.length >= 2) {
    return 80;
  }
  if (n.length >= 2 && n.length <= key.length && key.contains(n)) {
    return 60;
  }
  if (n.length >= 3 && key.length >= 3 && key.contains(n)) {
    return 50;
  }
  return 0;
}

List<String> _aliasNorms(StructuredAction a) {
  return a.aliases.map((e) => normalizeName(e)).where((e) => e.isNotEmpty).toList();
}

/// Phase 6: fuzzy + group-by-name. Multiple name groups → name disambig first.
FuzzyPaymentQueryResult buildFuzzyPaymentResult({
  required String nameQuery,
  required List<StructuredAction> openPaymentDocs,
}) {
  final n = normalizeName(nameQuery);
  if (n.isEmpty) {
    return FuzzyPaymentQueryResult.empty();
  }
  final scored = <StructuredAction, int>{};
  for (final a in openPaymentDocs) {
    if (!_isOpenForQuery(a)) {
      continue;
    }
    final key = a.nameLower.isNotEmpty ? a.nameLower : normalizeName(a.name);
    final r = _rankForQuery(n, key, _aliasNorms(a));
    if (r > 0) {
      scored[a] = r;
    }
  }
  if (scored.isEmpty) {
    return FuzzyPaymentQueryResult.empty();
  }
  final byName = <String, List<StructuredAction>>{};
  for (final e in scored.entries) {
    final a = e.key;
    final nl = a.nameLower.isNotEmpty ? a.nameLower : normalizeName(a.name);
    byName.putIfAbsent(nl, () => []).add(a);
  }
  for (final e in byName.entries) {
    e.value.sort((a, b) {
      return (a.date?.millisecondsSinceEpoch ?? 0)
          .compareTo(b.date?.millisecondsSinceEpoch ?? 0);
    });
  }
  if (byName.length == 1) {
    final list = byName.values.first;
    var maxR = 0;
    for (final a in list) {
      maxR = math.max(maxR, scored[a] ?? 0);
    }
    String? aLearn;
    String? aLow;
    if (list.isNotEmpty && maxR > 0 && maxR < 95) {
      aLearn = n;
      final f = list.first;
      aLow = f.nameLower.isNotEmpty ? f.nameLower : normalizeName(f.name);
    }
    return FuzzyPaymentQueryResult._(
      actions: list,
      aliasLearnNameLower: aLow,
      aliasLearnToken: aLearn,
    );
  }
  final groups = <FuzzyNameGroup>[];
  for (final e in byName.entries) {
    final first = e.value.isNotEmpty ? e.value.first : null;
    final label = first?.name.isNotEmpty == true ? first!.name : e.key;
    groups.add(
      FuzzyNameGroup(
        nameLower: e.key,
        displayName: label,
        actions: e.value,
      ),
    );
  }
  groups.sort((a, b) => a.displayName.compareTo(b.displayName));
  return FuzzyPaymentQueryResult.nameDisambig(groups);
}
