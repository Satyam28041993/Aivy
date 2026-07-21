import 'package:cloud_firestore/cloud_firestore.dart';

import 'in_app_notification_item.dart';

class InAppNotificationsRepository {
  InAppNotificationsRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _col(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('notifications');
  }

  /// Live list, newest first.
  Stream<List<InAppNotificationItem>> watchNotifications(
    String userId, {
    int limit = 100,
  }) {
    return _col(userId)
        .orderBy('createdAtMs', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (s) => s.docs
              .map(
                (d) => InAppNotificationItem.fromDoc(d),
              )
              .toList(growable: false),
        );
  }

  /// Count of documents with `read == false`.
  Stream<int> watchUnreadCount(String userId) {
    return _col(userId)
        .where('read', isEqualTo: false)
        .snapshots()
        .map((s) => s.docs.length);
  }

  Future<void> markAsRead(String userId, String notificationId) async {
    await _col(userId).doc(notificationId).set(
      {
        'read': true,
        'readAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }
}
