import 'package:flutter_test/flutter_test.dart';

import 'package:aivy/features/dashboard/models/morning_brief.dart';

/// The brief is drawn from whatever Firestore hands back, and the two things
/// that have gone wrong here before were both silent: a section vanishing
/// because it had no items, and a line vanishing because the words arrived in
/// a field the parser was not reading. These pin both, plus the tone that
/// marks late work.
void main() {
  group('BriefItem', () {
    test('reads the tone that colours a line', () {
      final item = BriefItem.fromMap(<String, dynamic>{
        'headline': 'Security label PPT',
        'detail': 'Mandar sir · 1 day late',
        'tone': 'late',
      });
      expect(item, isNotNull);
      expect(item!.tone, 'late');
      expect(item.detail, 'Mandar sir · 1 day late');
    });

    test('leaves tone null when it is absent or blank', () {
      final plain = BriefItem.fromMap(<String, dynamic>{'headline': 'A thing'});
      expect(plain!.tone, isNull);

      final blank = BriefItem.fromMap(<String, dynamic>{
        'headline': 'A thing',
        'tone': '   ',
      });
      expect(blank!.tone, isNull);
    });
  });

  group('BriefSection', () {
    test('an empty section still earns its heading', () {
      // It used to be dropped, which is how the whole alerts section
      // disappeared without a word.
      final section = BriefSection.fromMap(<String, dynamic>{
        'kind': 'tasks',
        'title': 'Your tasks',
        'items': <dynamic>[],
      });
      expect(section, isNotNull);
      expect(section!.worthShowing, isTrue);
      expect(section.emptyNote, isNotNull);
    });

    test('keeps the order the server sent, late first', () {
      final brief = MorningBrief.fromMap(<String, dynamic>{
        'sections': <dynamic>[
          <String, dynamic>{
            'kind': 'tasks',
            'title': 'Your tasks',
            'items': <dynamic>[
              <String, dynamic>{'headline': 'PPT', 'tone': 'late'},
              <String, dynamic>{'headline': 'Movie ticket', 'tone': 'due'},
            ],
          },
          <String, dynamic>{
            'kind': 'projects',
            'title': 'Projects',
            'items': <dynamic>[
              <String, dynamic>{'headline': 'Pune mudrank'},
            ],
          },
        ],
      });

      expect(brief.sections.map((s) => s.kind).toList(), ['tasks', 'projects']);
      expect(brief.sections.first.items.first.headline, 'PPT');
      expect(brief.sections.first.items.first.tone, 'late');
      expect(brief.sections.last.items.first.tone, isNull);
    });
  });
}
