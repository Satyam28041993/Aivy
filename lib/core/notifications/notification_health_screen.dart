import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import 'notification_service.dart';
import 'push_registration.dart';

/// Why a reminder did or did not arrive, in plain terms.
///
/// Every link in the chain — permission, the alarm queued on the OS, whether
/// this phone registered for push, and whether the server can actually reach
/// it — is invisible from a phone, and they all fail the same way: silence.
/// This puts each one on its own line, and ends with a button that exercises
/// the whole path on demand rather than waiting for the next reminder to find
/// out.
class NotificationHealthScreen extends StatefulWidget {
  const NotificationHealthScreen({super.key, required this.userId});

  final String userId;

  @override
  State<NotificationHealthScreen> createState() =>
      _NotificationHealthScreenState();
}

class _NotificationHealthScreenState extends State<NotificationHealthScreen> {
  NotificationHealth? _health;
  int _devices = 0;
  int _pendingReminders = 0;
  String? _result;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    final health = await NotificationService.instance.health();

    var devices = 0;
    var reminders = 0;
    try {
      final user = FirebaseFirestore.instance.collection('users').doc(widget.userId);
      devices = (await user.collection('devices').get()).size;
      // Only reminders still ahead of us. A reminder whose time has passed is
      // deliberately never put on the clock — counting those made this line
      // read red when nothing was wrong.
      reminders = (await user
              .collection('reminders')
              .where('status', isEqualTo: 'pending')
              .where('scheduledTimeMs',
                  isGreaterThan: DateTime.now().millisecondsSinceEpoch)
              .get())
          .size;
    } catch (e) {
      debugPrint('NotificationHealthScreen: read failed: $e');
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _health = health;
      _devices = devices;
      _pendingReminders = reminders;
      _busy = false;
    });
  }

  Future<void> _grant() async {
    await NotificationService.instance.requestPermissionsAgain();
    await _refresh();
  }

  Future<void> _registerAgain() async {
    setState(() => _busy = true);
    await PushRegistration().register(widget.userId);
    await _refresh();
  }

  /// Fires a notification with no server and no network involved.
  ///
  /// This is the half of the chain the test push cannot separate: if the push
  /// says "sent" and nothing appears, either FCM never delivered it or this
  /// phone cannot draw a notification at all. This answers that on its own.
  Future<void> _showLocal() async {
    await NotificationService.instance.showReminderNow(
      title: 'Aivy local test',
      body: 'Drawn by the app itself, with no server involved.',
      tag: 'local_test',
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _result = 'Asked Android to show a notification right now. If this one '
          'does not appear either, the problem is on the phone, not in '
          'delivery.';
    });
  }

  Future<void> _sendTest() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final res = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable('aivyTestPush')
          .call<Map<String, dynamic>>();
      final devices = (res.data['devices'] as num?)?.toInt() ?? 0;
      final sent = (res.data['sent'] as num?)?.toInt() ?? 0;
      setState(() {
        if (sent > 0) {
          _result = 'Sent to $sent device(s). Watch the "Pushes received" line '
              'above: if it goes up, the message reached this phone and the '
              'problem is only in showing it. If it stays put, the phone never '
              'got it.';
        } else if (devices == 0) {
          _result = 'Nothing to send to: no device is registered. '
              'Tap "Register this phone".';
        } else {
          _result = '$devices device(s) registered but delivery failed — the '
              'token is stale. Tap "Register this phone" and try again.';
        }
      });
    } catch (e) {
      setState(() => _result = 'Could not send: $e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = _health;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (h == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (!h.supported)
            const _Check(
              ok: false,
              title: 'Not available in a browser',
              detail: 'Notifications need the Android app. Everything else '
                  'works on the web.',
            )
          else ...[
            _Check(
              ok: h.notificationsEnabled,
              title: h.notificationsEnabled
                  ? 'Notifications allowed'
                  : 'Notifications are blocked',
              detail: h.notificationsEnabled
                  ? 'Aivy may show notifications on this phone.'
                  : 'Nothing arrives until this is allowed — not a reminder, '
                      'not a payment alert. This is the usual reason for silence.',
            ),
            _Check(
              ok: h.canScheduleExactAlarms,
              title: h.canScheduleExactAlarms
                  ? 'Exact alarms allowed'
                  : 'Exact alarms not allowed',
              detail: h.canScheduleExactAlarms
                  ? 'Reminders fire on the minute.'
                  : 'Reminders still arrive, but Android may hold them a few '
                      'minutes rather than firing at the exact time.',
            ),
            _Check(
              ok: _devices > 0,
              title: _devices > 0
                  ? 'This phone is registered for push'
                  : 'No device registered for push',
              detail: _devices > 0
                  ? '$_devices device(s) registered, so the server can reach you '
                      'with the app closed.'
                  : 'Without this the server has nowhere to send. Register below.',
            ),
            _Check(
              ok: PushRegistration.received > 0,
              title: 'Pushes received: ${PushRegistration.received}',
              detail: PushRegistration.received > 0
                  ? 'Messages have reached this phone, so delivery works.'
                  : 'Nothing has arrived yet. Send a test below, then pull '
                      'refresh — if this stays at zero, FCM accepted the '
                      'message but never delivered it.',
            ),
            _Check(
              ok: PushRegistration.lastToken != null,
              title: PushRegistration.lastToken != null
                  ? 'Token: …${PushRegistration.lastToken!.substring(
                      PushRegistration.lastToken!.length - 12,
                    )}'
                  : 'No token on this device',
              detail: PushRegistration.lastToken != null
                  ? 'The address the server sends to. It changes on reinstall.'
                  : 'Firebase Messaging never issued one — tap "Register this '
                      'phone".',
            ),
            _Check(
              ok: h.scheduledCount >= _pendingReminders,
              title: 'Alarms queued: ${h.scheduledCount}',
              detail: _pendingReminders == 0
                  ? 'No reminders are due in the future, so there is nothing to '
                      'queue. Set one and this number should go up.'
                  : '$_pendingReminders reminder(s) still due. These should '
                      'match — fewer alarms means some never reached this '
                      "phone's clock.",
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _grant,
            icon: const Icon(Icons.lock_open),
            label: const Text('Ask for permission again'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _registerAgain,
            icon: const Icon(Icons.phonelink_ring),
            label: const Text('Register this phone'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _showLocal,
            icon: const Icon(Icons.notifications),
            label: const Text('Show a notification right now (no server)'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _sendTest,
            icon: const Icon(Icons.send),
            label: const Text('Send me a test push (through the server)'),
          ),
          if (_result != null) ...[
            const SizedBox(height: 14),
            Text(_result!),
          ],
          const SizedBox(height: 26),
          Text(
            'If every line above is green and the test still does not arrive, '
            'the phone itself is stopping it. Settings → Apps → Aivy → Battery '
            '→ Unrestricted. On Xiaomi, Oppo, Vivo and Realme, turn Autostart '
            'on as well. Force-stopping the app blocks notifications until it '
            'is opened again — that is Android, and it happens to WhatsApp too.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({required this.ok, required this.title, required this.detail});

  final bool ok;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.error,
            color: ok ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
