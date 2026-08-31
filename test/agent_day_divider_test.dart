import 'package:flutter_test/flutter_test.dart';

import 'package:aivy/features/agent/presentation/widgets/agent_message_bubble.dart';

/// A time on its own is ambiguous the moment a chat runs past midnight, so the
/// divider is what makes every timestamp above it mean something.
void main() {
  int at(int y, int m, int d, [int h = 12]) =>
      DateTime(y, m, d, h).millisecondsSinceEpoch;

  group('AgentDayDivider.needed', () {
    test('is true only when the local day changes', () {
      expect(AgentDayDivider.needed(at(2026, 8, 31, 9), at(2026, 8, 31, 23)), isFalse);
      expect(AgentDayDivider.needed(at(2026, 8, 31, 23), at(2026, 9, 1, 1)), isTrue);
    });

    test('is false when either message has no time', () {
      // An optimistic local message can arrive before its timestamp does;
      // that must not draw a divider dated 1970.
      expect(AgentDayDivider.needed(0, at(2026, 9, 1)), isFalse);
      expect(AgentDayDivider.needed(at(2026, 9, 1), 0), isFalse);
    });
  });

  group('AgentDayDivider.label', () {
    final now = DateTime(2026, 9, 1, 19, 19);

    test('names the recent days the way a person would', () {
      expect(AgentDayDivider.label(at(2026, 9, 1), now: now), 'Today');
      expect(AgentDayDivider.label(at(2026, 8, 31), now: now), 'Yesterday');
    });

    test('uses the weekday inside the week and the date beyond it', () {
      // 28 August 2026 is a Friday, four days back.
      expect(AgentDayDivider.label(at(2026, 8, 28), now: now), 'Friday');
      expect(AgentDayDivider.label(at(2026, 8, 1), now: now), '1 August 2026');
    });
  });
}
