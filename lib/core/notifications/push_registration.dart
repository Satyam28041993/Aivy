import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'notification_service.dart';

/// Registers this device for push, so a reminder arrives with Aivy closed.
///
/// The local alarm set alongside it covers the case where the phone is offline
/// at the moment a reminder is due. It cannot cover everything: an alarm is
/// lost when the user force-stops the app, and a reminder created on another
/// device is not on this one's clock at all. Push comes from the server, which
/// knows the reminder fired regardless of what this phone was doing.
///
/// The token lands in `users/{uid}/devices/{id}`, which the server reads.
class PushRegistration {
  PushRegistration({
    FirebaseFirestore? firestore,
    FirebaseMessaging? messaging,
    NotificationService? notifications,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _messaging = messaging ?? FirebaseMessaging.instance,
        _notifications = notifications ?? NotificationService.instance;

  final FirebaseFirestore _firestore;
  final FirebaseMessaging _messaging;
  final NotificationService _notifications;

  /// A token is longer than a document id may be and carries characters a path
  /// cannot, so the id is a bounded, path-safe tail of it. Must match the
  /// server, which deletes by the same id when a token stops working.
  static String tokenDocId(String token) {
    final safe = token.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    if (safe.isEmpty) {
      return 'device';
    }
    return safe.length <= 120 ? safe : safe.substring(safe.length - 120);
  }

  bool get _supported {
    if (kIsWeb) {
      // Web push needs a VAPID key and a service worker of its own; the browser
      // build shows notifications in the app instead.
      return false;
    }
    return Platform.isAndroid || Platform.isIOS;
  }

  Future<void> register(String userId) async {
    if (userId.isEmpty || !_supported) {
      return;
    }
    try {
      // Android 13+ and iOS both gate notifications behind this. Declining is
      // an answer, not an error — everything else still works.
      final settings = await _messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('PushRegistration: notifications declined');
        return;
      }

      final token = await _messaging.getToken();
      if (token != null && token.isNotEmpty) {
        await _save(userId, token);
      }

      // Tokens rotate — on reinstall, on restore, and occasionally on their
      // own. A stale one silently stops delivering, so the new one is stored
      // as soon as it is issued.
      _messaging.onTokenRefresh.listen(
        (t) => _save(userId, t),
        onError: (Object e) => debugPrint('PushRegistration: refresh failed: $e'),
      );

      // With the app open Android does not draw an arriving push, so it is
      // drawn here. Closed or backgrounded, the system tray handles it and this
      // never runs.
      FirebaseMessaging.onMessage.listen(_showForeground);
    } catch (e, st) {
      debugPrint('PushRegistration: could not register: $e\n$st');
    }
  }

  Future<void> _save(String userId, String token) async {
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('devices')
          .doc(tokenDocId(token))
          .set({
        'token': token,
        'platform': kIsWeb ? 'web' : Platform.operatingSystem,
        'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('PushRegistration: could not save token: $e');
    }
  }

  Future<void> _showForeground(RemoteMessage message) async {
    final n = message.notification;
    final title = (n?.title ?? '').trim();
    final body = (n?.body ?? '').trim();
    if (title.isEmpty && body.isEmpty) {
      return;
    }
    // Tagged by reminder where there is one, so the push and the local alarm
    // for the same reminder land on one notification instead of two.
    final tag = message.data['reminderId']?.toString().trim();
    await _notifications.showReminderNow(
      title: title.isNotEmpty ? title : 'Aivy',
      body: body,
      tag: (tag != null && tag.isNotEmpty) ? tag : message.messageId ?? title,
    );
  }
}
