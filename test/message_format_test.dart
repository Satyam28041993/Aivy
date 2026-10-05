import 'package:flutter_test/flutter_test.dart';

import 'package:aivy/features/agent/presentation/widgets/message_format.dart';

void main() {
  group('boldRuns', () {
    test('turns **marks** into bold runs without the asterisks', () {
      expect(boldRuns('I recommend the **T6000e** for this.'), const [
        TextRun('I recommend the '),
        TextRun('T6000e', bold: true),
        TextRun(' for this.'),
      ]);
    });

    test('handles several bold runs and a numbered list', () {
      final runs = boldRuns('1. **B-EX4T1:** fast\n2. **B-EX4T2:** cheaper');
      expect(runs.where((r) => r.bold).map((r) => r.text),
          ['B-EX4T1:', 'B-EX4T2:']);
      expect(runs.map((r) => r.text).join(), '1. B-EX4T1: fast\n2. B-EX4T2: cheaper');
    });

    test('leaves an unmatched ** as written', () {
      expect(boldRuns('5 ** 2'), const [TextRun('5 ** 2')]);
    });

    test('leaves plain text alone', () {
      expect(boldRuns('Nothing due today.'), const [TextRun('Nothing due today.')]);
    });
  });

  test('stripBold removes the marks only', () {
    expect(stripBold('See **BV400** and **BA400**.'), 'See BV400 and BA400.');
  });
}
