import 'package:flutter_test/flutter_test.dart';

import 'package:aivy/features/agent/presentation/widgets/message_links.dart';

void main() {
  group('extractLinks', () {
    test('pulls a map link out of a sentence and names it', () {
      const text =
          'You are in Mande, Maharashtra 401102. Here is the map link: '
          'https://www.google.com/maps/search/?api=1&query=19.56,72.80';
      final links = extractLinks(text);

      expect(links, hasLength(1));
      expect(links.first.label, 'Open in Maps');
      expect(links.first.url.endsWith('72.80'), isTrue);
    });

    test('tells a directions link apart from a pin', () {
      final links = extractLinks(
        'https://www.google.com/maps/search/?api=1&query=1,2 and '
        'https://www.google.com/maps/dir/?api=1&destination=1,2',
      );
      expect(links.map((l) => l.label), ['Open in Maps', 'Get directions']);
    });

    test('leaves the full stop with the sentence, not the address', () {
      final links = extractLinks('Open https://example.com/a.');
      expect(links.single.url, 'https://example.com/a');
      expect(links.single.label, 'example.com');
    });

    test('lists a repeated link once', () {
      final links = extractLinks('https://example.com/a https://example.com/a');
      expect(links, hasLength(1));
    });

    test('finds nothing in a reply with no link', () {
      expect(extractLinks('Saphale station is 2.1 km by road.'), isEmpty);
    });
  });

  group('stripLinks', () {
    test('removes the link and the colon that introduced it', () {
      const text = 'You are in Mande. Here is the map link: '
          'https://www.google.com/maps/search/?api=1&query=19.56,72.80';
      expect(
        stripLinks(text, extractLinks(text)),
        'You are in Mande. Here is the map link',
      );
    });

    test('drops a line that was nothing but a link', () {
      const text = 'Saphale station is 2.1 km by road.\n'
          'https://www.google.com/maps/dir/?api=1&destination=1,2';
      expect(
        stripLinks(text, extractLinks(text)),
        'Saphale station is 2.1 km by road.',
      );
    });

    test('leaves a reply without links untouched', () {
      const text = 'Nothing due today.';
      expect(stripLinks(text, extractLinks(text)), text);
    });
  });
}
