import 'package:aivy/features/reminders/utils/reminder_context_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Hinglish call + ke liye purpose', () {
    const s =
        'Rahul ko call karna hai artwork ke liye aaj 3 baje reminder laga do';
    final p = ReminderContextParser.parse(s);
    expect(p.isStructured, isTrue);
    expect(p.type, 'call');
    expect(p.action, 'call');
    expect(p.client, 'Rahul');
    expect(p.title, 'Call Rahul');
    expect(p.description, 'Artwork discussion');
  });

  test('fallback: unstructured text uses first words, not generic label', () {
    final p = ReminderContextParser.parse('do something important later');
    expect(p.isStructured, isTrue);
    expect(p.title, 'Do Something Important Later');
    expect(p.description, isNotNull);
  });

  test('hinglish: time between ko and call still parses client', () {
    const s = 'rajesh ko aaj 3 baje call karna hai artwork ke liye';
    final p = ReminderContextParser.parse(s);
    expect(p.isStructured, isTrue);
    expect(p.client, 'Rajesh');
    expect(p.title, 'Call Rajesh');
    expect(p.description, 'Artwork discussion');
  });
}
