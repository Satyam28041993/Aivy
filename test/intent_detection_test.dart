import 'package:aivy/features/chat/utils/intent_detection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('who to call today is query (analytics), not new-reminder scheduling', () {
    final i = detectIntent('aaj mujhe kise call karna hai');
    expect(i, AivyUserIntent.query);
  });

  test('schedule without "reminder" word is still reminder', () {
    final i = detectIntent('rajesh ko aaj 3 baje call karna hai');
    expect(i, AivyUserIntent.reminder);
  });

  test('collection line is payment', () {
    final i = detectIntent('karan se 50000 lena hai 5 din baad');
    expect(i, AivyUserIntent.payment);
  });

  test('quotation stat question is query', () {
    final i = detectIntent('aaj kitna quotation banaya');
    expect(i, AivyUserIntent.query);
  });
}
