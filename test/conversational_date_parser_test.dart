import 'package:aivy/features/chat/utils/conversational_date_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ref = DateTime(2026, 5, 2);

  DateTime d(String s) => parseConversationalDate(s, reference: ref)!;

  group('parseConversationalDate', () {
    test('empty → reference day', () {
      expect(
        parseConversationalDate('', reference: ref),
        DateTime(2026, 5, 2),
      );
      expect(
        parseConversationalDate('   ', reference: ref),
        DateTime(2026, 5, 2),
      );
    });

    test('Hindi / English relatives', () {
      expect(d('aaj'), DateTime(2026, 5, 2));
      expect(d('Aaj'), DateTime(2026, 5, 2));
      expect(d('AAJ'), DateTime(2026, 5, 2));
      expect(d('aaj ka'), DateTime(2026, 5, 2));
      expect(d('kal'), DateTime(2026, 5, 3));
      expect(d('kal ka'), DateTime(2026, 5, 3));
      expect(d('parso'), DateTime(2026, 5, 4));
      expect(d('today'), DateTime(2026, 5, 2));
      expect(d('tomorrow'), DateTime(2026, 5, 3));
      expect(d('yesterday'), DateTime(2026, 5, 1));
    });

    test('named months', () {
      expect(d('2 may'), DateTime(2026, 5, 2));
      expect(d('10 may'), DateTime(2026, 5, 10));
      expect(d('10 May'), DateTime(2026, 5, 10));
      expect(d('2 May 2026'), DateTime(2026, 5, 2));
      expect(d('5 May 2026'), DateTime(2026, 5, 5));
      expect(d('may 5'), DateTime(2026, 5, 5));
      expect(d('may 5 2026'), DateTime(2026, 5, 5));
      expect(d('5th may'), DateTime(2026, 5, 5));
    });

    test('fullwidth Latin normalizes', () {
      expect(
        parseConversationalDate('ＡＡＪ', reference: ref),
        DateTime(2026, 5, 2),
      );
    });

    test('numeric', () {
      expect(d('02/05/2026'), DateTime(2026, 5, 2));
      expect(d('5-5-2026'), DateTime(2026, 5, 5));
      expect(d('5/05/2026'), DateTime(2026, 5, 5));
    });
  });
}
