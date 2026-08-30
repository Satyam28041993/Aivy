import 'package:flutter_test/flutter_test.dart';

import 'package:aivy/core/notifications/push_registration.dart';

void main() {
  group('PushRegistration.tokenDocId', () {
    // The server deletes by this id when a token stops working, so the two
    // sides have to derive the same id from the same token.
    test('strips the characters a Firestore path cannot hold', () {
      expect(
        PushRegistration.tokenDocId('abc/def:ghi.jkl'),
        'abcdefghijkl',
      );
    });

    test('keeps hyphens and underscores, which FCM tokens really contain', () {
      expect(PushRegistration.tokenDocId('a-b_c'), 'a-b_c');
    });

    test('bounds a long token to its tail', () {
      final id = PushRegistration.tokenDocId('x' * 300);
      expect(id.length, 120);
    });

    test('never returns an empty id', () {
      expect(PushRegistration.tokenDocId('///'), 'device');
      expect(PushRegistration.tokenDocId(''), 'device');
    });

    test('is stable, so re-registering overwrites instead of piling up', () {
      const token = 'fcm:token/one_two-three';
      expect(
        PushRegistration.tokenDocId(token),
        PushRegistration.tokenDocId(token),
      );
    });
  });
}
