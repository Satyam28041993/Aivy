import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// What the OS will and will not let this app do about notifications.
@immutable
class NotificationHealth {
  const NotificationHealth({
    required this.supported,
    required this.notificationsEnabled,
    required this.canScheduleExactAlarms,
    required this.scheduledCount,
    this.channelEnabled = true,
    this.channelState = 'unknown',
  });

  /// False on web, where none of this exists.
  final bool supported;

  /// Denied here and nothing displays at all — neither an alarm nor a push.
  final bool notificationsEnabled;

  /// Denied here and reminders still arrive, but the OS may hold them for a
  /// few minutes rather than firing on the exact minute.
  final bool canScheduleExactAlarms;

  /// Alarms currently queued on the OS, which should match the pending
  /// reminders. Zero with reminders pending means they were never scheduled.
  final int scheduledCount;

  /// Android lets a single channel be silenced while the app as a whole still
  /// reports notifications as allowed. Everything here — the alarm, the push,
  /// the local test — goes through one channel, so this is the difference
  /// between "blocked" and "nothing was sent".
  final bool channelEnabled;

  /// Whatever the OS calls this channel's importance, for when it is neither
  /// plainly on nor plainly off.
  final String channelState;

  bool get healthy => supported && notificationsEnabled && channelEnabled;
}

/// Thin wrapper around `flutter_local_notifications` that exposes a single
/// entry point to schedule reminder notifications.
///
/// The service is a singleton so it can be reached from both bootstrap code
/// (e.g. `main.dart`) and from repositories that create reminders (e.g.
/// `ChatRepository`).
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  /// The last thing that went wrong, kept so the health screen can show it.
  /// Every failure in here used to go to debugPrint, which is invisible on a
  /// phone — so a notification that never appeared had no explanation at all.
  static String? lastError;

  static void _note(Object error, String where) {
    lastError = '$where: $error';
    debugPrint('NotificationService: $where: $error');
  }

  /// v3, and deliberately without a custom sound.
  ///
  /// A channel's settings are fixed once Android has created it, so the only
  /// way to change one is a new id. v2 carried a raw-resource sound, and on
  /// some builds a channel whose sound URI will not resolve accepts
  /// notifications and shows nothing — which is exactly the symptom here:
  /// pushes arriving, the app reporting no error, and a silent screen. A
  /// channel that is off cannot be switched back on in code either, and a new
  /// id starts on. This drops the custom tone and takes the system's default
  /// notification sound, which always resolves.
  static const String _reminderChannelId = 'aivy_reminders_v3';
  static const String _retiredReminderChannelId = 'aivy_reminders_v2';
  static const String _reminderChannelName = 'Reminders';
  static const String _reminderChannelDescription =
      'Scheduled reminders created from Aivy conversations.';

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
      // One reminder has two ways of arriving — this alarm, and the server's
      // push a few minutes later — and without a shared tag Android draws
      // both. Tagging by reminder makes the second replace the first.
      tag: reminderId,
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
    } on PlatformException catch (error) {
      // On Android 12+ exact alarms may be denied by the user. Fall back to
      // an inexact schedule so the reminder still fires, just not guaranteed
      // to the minute.
      _note(error, 'exact alarm refused for "$reminderId", using inexact');
      await _plugin.zonedSchedule(
        notificationId,
        title,
        body,
        zonedTime,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: reminderId,
      );
    } catch (error) {
      // Anything else means no alarm was queued at all, which is the failure
      // that leaves "alarms queued: 0" with reminders still due.
      _note(error, 'scheduling "$reminderId"');
      rethrow;
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
      tag: tag,
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
    } catch (error) {
      _note(error, 'showing "$tag"');
      rethrow;
    }
  }

  /// What the OS currently allows, and what is actually queued on it.
  ///
  /// A reminder that does not arrive has several possible causes that look
  /// identical from the outside — permission never granted, exact alarms
  /// refused, or nothing scheduled at all — and none of them are visible from
  /// a phone. This reports each separately so the real one can be seen.
  Future<NotificationHealth> health() async {
    if (!_initialized) {
      await initialize();
    }
    if (kIsWeb) {
      return const NotificationHealth(
        supported: false,
        notificationsEnabled: false,
        canScheduleExactAlarms: false,
        scheduledCount: 0,
      );
    }

    var enabled = true;
    var exact = true;
    var channelOn = true;
    var channelState = 'not applicable';
    if (Platform.isAndroid) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      enabled = await android?.areNotificationsEnabled() ?? false;
      exact = await android?.canScheduleExactNotifications() ?? false;

      try {
        final channels = await android?.getNotificationChannels() ?? [];
        final mine = channels
            .where((c) => c.id == _reminderChannelId)
            .toList(growable: false);
        if (mine.isEmpty) {
          channelOn = false;
          channelState = 'missing';
        } else {
          // Importance is a value class here, not an enum, so it is compared
          // and reported by its number. Zero is a channel switched off.
          final importance = mine.first.importance.value;
          channelOn = importance > Importance.none.value;
          channelState = switch (importance) {
            <= 0 => 'off',
            1 => 'minimum',
            2 => 'low',
            3 => 'default (silent pop-up)',
            _ => 'high',
          };
        }
      } catch (error) {
        _note(error, 'reading channels');
        channelState = 'could not read';
      }
    }

    var pending = 0;
    try {
      pending = (await _plugin.pendingNotificationRequests()).length;
    } catch (error) {
      _note(error, 'reading queued alarms');
    }

    return NotificationHealth(
      supported: true,
      notificationsEnabled: enabled,
      canScheduleExactAlarms: exact,
      scheduledCount: pending,
      channelEnabled: channelOn,
      channelState: channelState,
    );
  }

  /// Asks again for whatever was declined. Android only shows its own dialog
  /// once, so this may open Settings instead — which is the honest outcome.
  Future<void> requestPermissionsAgain() async {
    if (!_initialized) {
      await initialize();
      return;
    }
    await _requestPermissions();
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
      enableVibration: true,
    );
    await androidPlugin.createNotificationChannel(channel);
    // The old channel would otherwise sit in Settings forever, and a user
    // looking for "Reminders" could well find the dead one.
    try {
      await androidPlugin.deleteNotificationChannel(_retiredReminderChannelId);
    } catch (error) {
      _note(error, 'removing the old channel');
    }
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
