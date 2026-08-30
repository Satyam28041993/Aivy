import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// Thin wrapper around `flutter_local_notifications` that exposes a single
/// entry point to schedule reminder notifications.
///
/// The service is a singleton so it can be reached from both bootstrap code
/// (e.g. `main.dart`) and from repositories that create reminders (e.g.
/// `ChatRepository`).
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  /// New id (v2) so Android recreates the channel: channel sound/vibration
  /// cannot be changed after the first create on many devices.
  static const String _reminderChannelId = 'aivy_reminders_v2';
  static const String _reminderChannelName = 'Reminders';
  static const String _reminderChannelDescription =
      'Scheduled reminders created from Aivy conversations.';

  /// Bundled under `android/app/src/main/res/raw/aivy_reminder.mp3` so the
  /// tone plays even when the system default notification sound is silent.
  static const AndroidNotificationSound _reminderAndroidSound =
      RawResourceAndroidNotificationSound('aivy_reminder');

  static const String _nudgeChannelId = 'aivy_nudges';
  static const String _nudgeChannelName = 'Aivy Nudges';
  static const String _nudgeChannelDescription =
      'Passive reminders about pending tasks and missed reminders.';

  static const int _nudgeNotificationId = 0x6E646765; // 'ndge'

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Initializes the plugin, configures the local timezone database and
  /// requests runtime permissions. Safe to call multiple times.
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    tz.initializeTimeZones();
    try {
      final localName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(localName));
    } catch (error, stackTrace) {
      debugPrint('NotificationService: failed to resolve local timezone: '
          '$error\n$stackTrace');
    }

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
    );

    await _plugin.initialize(settings);
    await _ensureAndroidChannel();
    await _ensureNudgeChannel();
    await _requestPermissions();

    _initialized = true;
  }

  /// Shows an immediate local notification summarizing how many pending
  /// actions the user has. Used by the passive agent nudge flow on app
  /// launch when the throttle allows.
  Future<void> showPassiveNudgeNotification({required int pendingCount}) async {
    if (!_initialized) {
      await initialize();
    }
    if (pendingCount <= 0) {
      return;
    }

    final title = 'Aivy';
    final body = pendingCount == 1
        ? 'You have 1 pending action. Open Aivy to act.'
        : 'You have $pendingCount pending actions. Open Aivy to act.';

    const androidDetails = AndroidNotificationDetails(
      _nudgeChannelId,
      _nudgeChannelName,
      channelDescription: _nudgeChannelDescription,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      category: AndroidNotificationCategory.reminder,
      onlyAlertOnce: true,
    );
    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: false,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );

    try {
      await _plugin.show(
        _nudgeNotificationId,
        title,
        body,
        details,
        payload: 'passive_nudge',
      );
    } catch (error, stackTrace) {
      debugPrint(
        'NotificationService: failed to show passive nudge: $error\n$stackTrace',
      );
    }
  }

  /// Schedules a single local notification that fires at [scheduledTime].
  ///
  /// [reminderId] is used as a stable key so the same reminder can be
  /// rescheduled or cancelled without piling up duplicate notifications.
  Future<void> scheduleReminderNotification({
    required String title,
    required String body,
    String? subtitle,
    required DateTime scheduledTime,
    required String reminderId,
  }) async {
    if (!_initialized) {
      await initialize();
    }

    final notificationId = _notificationIdFor(reminderId);
    final zonedTime = _resolveZonedTime(scheduledTime);

    // If the reminder is already in the past we skip scheduling so the OS
    // does not fire an immediate, possibly surprising, notification.
    if (zonedTime.isBefore(tz.TZDateTime.now(tz.local))) {
      debugPrint(
        'NotificationService: skipping reminder "$reminderId" because '
        'scheduledTime ($scheduledTime) is in the past.',
      );
      return;
    }

    final darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      subtitle: subtitle,
    );
    final androidDetailsWithSubtitle = AndroidNotificationDetails(
      _reminderChannelId,
      _reminderChannelName,
      channelDescription: _reminderChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      subText: subtitle,
      playSound: true,
      sound: _reminderAndroidSound,
    );
    final details = NotificationDetails(
      android: androidDetailsWithSubtitle,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );

    try {
      await _plugin.zonedSchedule(
        notificationId,
        title,
        body,
        zonedTime,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: reminderId,
      );
    } on PlatformException catch (error, stackTrace) {
      // On Android 12+ exact alarms may be denied by the user. Fall back to
      // an inexact schedule so the reminder still fires, just not guaranteed
      // to the minute.
      debugPrint(
        'NotificationService: exact alarm rejected for "$reminderId" '
        '($error). Falling back to inexact schedule.\n$stackTrace',
      );
      await _plugin.zonedSchedule(
        notificationId,
        title,
        body,
        zonedTime,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: reminderId,
      );
    }
  }

  /// Shows a reminder immediately, on the same channel as a scheduled one.
  ///
  /// Android's system tray draws a push itself while the app is closed, but
  /// stays silent when the app is in the foreground — so a push that arrives
  /// while the user is looking at the app is drawn here instead. [tag] keeps a
  /// push and its local alarm on one notification id rather than two, so the
  /// same reminder never appears twice.
  Future<void> showReminderNow({
    required String title,
    required String body,
    String? subtitle,
    required String tag,
  }) async {
    if (!_initialized) {
      await initialize();
    }
    final androidDetails = AndroidNotificationDetails(
      _reminderChannelId,
      _reminderChannelName,
      channelDescription: _reminderChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      subText: subtitle,
      playSound: true,
      sound: _reminderAndroidSound,
    );
    final darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      subtitle: subtitle,
    );
    try {
      await _plugin.show(
        _notificationIdFor(tag),
        title,
        body,
        NotificationDetails(
          android: androidDetails,
          iOS: darwinDetails,
          macOS: darwinDetails,
        ),
        payload: tag,
      );
    } catch (error, stackTrace) {
      debugPrint(
        'NotificationService: failed to show reminder "$tag": '
        '$error\n$stackTrace',
      );
    }
  }

  /// Cancels a previously scheduled reminder, if any.
  Future<void> cancelReminderNotification(String reminderId) async {
    if (!_initialized) {
      return;
    }
    await _plugin.cancel(_notificationIdFor(reminderId));
  }

  Future<void> _ensureAndroidChannel() async {
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin == null) {
      return;
    }

    const channel = AndroidNotificationChannel(
      _reminderChannelId,
      _reminderChannelName,
      description: _reminderChannelDescription,
      importance: Importance.high,
      playSound: true,
      sound: _reminderAndroidSound,
      enableVibration: true,
    );
    await androidPlugin.createNotificationChannel(channel);
  }

  Future<void> _ensureNudgeChannel() async {
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin == null) {
      return;
    }

    const channel = AndroidNotificationChannel(
      _nudgeChannelId,
      _nudgeChannelName,
      description: _nudgeChannelDescription,
      importance: Importance.defaultImportance,
    );
    await androidPlugin.createNotificationChannel(channel);
  }

  Future<void> _requestPermissions() async {
    if (kIsWeb) {
      return;
    }

    if (Platform.isAndroid) {
      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      // Android 13+ (API 33) requires the runtime POST_NOTIFICATIONS
      // permission. Older versions simply return `true`.
      await androidPlugin?.requestNotificationsPermission();
      // Exact alarms need user consent on Android 12+. We still schedule
      // inexact alarms as a fallback if this is denied.
      await androidPlugin?.requestExactAlarmsPermission();
      return;
    }

    if (Platform.isIOS || Platform.isMacOS) {
      final iosPlugin = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      await iosPlugin?.requestPermissions(alert: true, badge: true, sound: true);

      final macPlugin = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      await macPlugin?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  tz.TZDateTime _resolveZonedTime(DateTime scheduledTime) {
    if (scheduledTime.isUtc) {
      return tz.TZDateTime.from(scheduledTime, tz.local);
    }
    return tz.TZDateTime(
      tz.local,
      scheduledTime.year,
      scheduledTime.month,
      scheduledTime.day,
      scheduledTime.hour,
      scheduledTime.minute,
      scheduledTime.second,
      scheduledTime.millisecond,
      scheduledTime.microsecond,
    );
  }

  /// Maps a Firestore reminder id (string) to the 32-bit integer id required
  /// by the platform notification APIs. Uses a stable hash so the same
  /// reminder id always yields the same notification id.
  int _notificationIdFor(String reminderId) {
    return reminderId.hashCode & 0x7fffffff;
  }
}
