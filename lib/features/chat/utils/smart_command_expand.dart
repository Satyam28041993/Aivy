/// Maps `/1`…`/10`, `*n`, `Qn`, and plain `1`…`10` to phrases the cloud
/// classifiers expect — keep in sync with `ANALYTICS_SHORTCUTS` in `aivyProcess.ts`.
String? expandSmartCommandInput(String raw) {
  final s0 = raw.trim();
  if (s0.isEmpty) {
    return null;
  }
  final patterns = <RegExp>[
    RegExp(r'^\s*/\s*(\d{1,2})\s*$'),
    RegExp(r'^\s*\*\s*(\d{1,2})\s*$'),
    RegExp(r'^\s*Q\s*(\d{1,2})\s*$', caseSensitive: false),
    RegExp(r'^\s*(\d{1,2})\s*$'),
  ];
  for (final re in patterns) {
    final m = re.firstMatch(s0);
    if (m != null) {
      final n = int.tryParse(m.group(1)!);
      if (n != null && n >= 1 && n <= 11) {
        return kSmartCommandQueries[n];
      }
    }
  }
  return null;
}

const Map<int, String> kSmartCommandQueries = {
  1: 'Top clients by business',
  2: 'This week payment follow-ups pending list',
  3: 'Highest pending client amount',
  4: 'Overdue payments list',
  5: 'Aaj follow up collection list',
  6: 'Full business status',
  7: 'Aaj kitne order aaye',
  8: 'Aaj kitna dispatch hua',
  9: 'Is mahine total kitna business order hua',
  10: 'Kaun risky client hai',
  11: 'Pending orders list',
};

class AivyQuickAction {
  const AivyQuickAction({
    required this.n,
    required this.label,
    required this.sendText,
  });

  final int n;
  final String label;
  final String sendText;
}

const List<AivyQuickAction> kAivyQuickActionBar = [
  AivyQuickAction(n: 1, label: 'Top Clients', sendText: 'Top clients by business'),
  AivyQuickAction(
    n: 2,
    label: 'This week payments',
    sendText: 'This week payment follow-ups pending list',
  ),
  AivyQuickAction(
    n: 3,
    label: 'Highest Pending',
    sendText: 'Highest pending client amount',
  ),
  AivyQuickAction(n: 4, label: 'Overdue', sendText: 'Overdue payments list'),
  AivyQuickAction(
    n: 5,
    label: 'Follow-ups',
    sendText: 'Aaj follow up collection list',
  ),
  AivyQuickAction(n: 6, label: 'Status', sendText: 'Full business status'),
];
