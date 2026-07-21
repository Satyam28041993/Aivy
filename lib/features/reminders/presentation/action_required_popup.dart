import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../services/audio_service.dart';
import '../../chat/data/chat_repository.dart';
import '../models/action_required_item.dart';
import '../models/reminder_item.dart';

const _kActionPopupCachePrefix = 'aivy_action_required_last_shown_ms_';
const _kActionPopupCoolDown = Duration(minutes: 10);

/// Called from the main dashboard after first frame. Respects 10 min cache.
Future<void> fetchImportantRemindersAndShowIfNeeded({
  required BuildContext context,
  required String userId,
  required ChatRepository repository,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final last = prefs.getInt('$_kActionPopupCachePrefix$userId') ?? 0;
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - last < _kActionPopupCoolDown.inMilliseconds) {
    return;
  }
  if (!context.mounted) {
    return;
  }

  final items = await repository.fetchImportantReminders(userId);
  if (items.isEmpty) {
    return;
  }

  // ignore: avoid_print
  debugPrint('Reminder popup triggered, count: ${items.length}');

  await prefs.setInt('$_kActionPopupCachePrefix$userId', now);

  if (!context.mounted) {
    return;
  }
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ActionRequiredDialog(
        userId: userId,
        repository: repository,
        initialItems: items,
      ),
    ),
  );
}

void _logReminderPopupError(Object e, StackTrace st) {
  debugPrint('ActionRequiredDialog: $e\n$st');
}

class _ActionRequiredDialog extends StatefulWidget {
  const _ActionRequiredDialog({
    required this.userId,
    required this.repository,
    required this.initialItems,
  });

  final String userId;
  final ChatRepository repository;
  final List<ActionRequiredItem> initialItems;

  @override
  State<_ActionRequiredDialog> createState() => _ActionRequiredDialogState();
}

class _ActionRequiredDialogState extends State<_ActionRequiredDialog> {
  late List<ActionRequiredItem> _items;
  final Set<String> _busy = {};
  static final _currency = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.initialItems);
    // ignore: avoid_print
    print('🔊 Reminder sound triggered');
    unawaited(AudioService.playReminder());
  }

  @override
  void dispose() {
    unawaited(AudioService.stop());
    super.dispose();
  }

  void _dismissIfEmpty() {
    if (_items.isEmpty) {
      Navigator.of(context).pop();
    }
  }

  String _formatInr(double v) => _currency.format(v);

  Color _lineColor(ActionRequiredItem item) {
    switch (item.bucket) {
      case ActionRequiredBucket.overdue:
        return const Color(0xFFEF4444);
      case ActionRequiredBucket.today:
        return const Color(0xFFFBBF24);
      case ActionRequiredBucket.upcoming:
        return const Color(0xFF38BDF8);
    }
  }

  Color _lineBackground(ActionRequiredItem item) {
    return _lineColor(item).withValues(alpha: 0.12);
  }

  Future<void> _onDone(ActionRequiredItem item) async {
    final key = item.id;
    if (_busy.contains(key)) {
      return;
    }
    await AudioService.stop();
    setState(() => _busy.add(key));
    try {
      if (item.source == ActionRequiredSource.payment && item.paymentId != null) {
        await widget.repository.markPaymentAsPaid(
          userId: widget.userId,
          paymentId: item.paymentId!,
        );
      } else if (item.reminderId != null) {
        await widget.repository.markReminderDone(
          userId: widget.userId,
          reminderId: item.reminderId!,
        );
      }
      if (mounted) {
        setState(() {
          _items.removeWhere((e) => e.id == item.id);
          _busy.remove(key);
        });
        _dismissIfEmpty();
      }
    } catch (e, st) {
      if (kDebugMode) {
        _logReminderPopupError(e, st);
      }
      if (mounted) {
        setState(() => _busy.remove(key));
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.showSnackBar(
          SnackBar(
            content: Text('Could not mark done: $e'),
            backgroundColor: const Color(0xFFB91C1C),
          ),
        );
      }
    }
  }

  Future<void> _onLater(ActionRequiredItem item) async {
    final key = item.id;
    if (_busy.contains(key)) {
      return;
    }
    await AudioService.stop();
    setState(() => _busy.add(key));
    try {
      if (item.source == ActionRequiredSource.payment && item.paymentId != null) {
        await widget.repository.pushPaymentDueByOneDay(
          userId: widget.userId,
          paymentId: item.paymentId!,
        );
      } else if (item.reminderId != null) {
        await widget.repository.pushReminderByOneDay(
          userId: widget.userId,
          reminderId: item.reminderId!,
        );
      }
      if (mounted) {
        setState(() {
          _items.removeWhere((e) => e.id == item.id);
          _busy.remove(key);
        });
        _dismissIfEmpty();
      }
    } catch (e, st) {
      if (kDebugMode) {
        _logReminderPopupError(e, st);
      }
      if (mounted) {
        setState(() => _busy.remove(key));
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text('Could not snooze: $e'),
            backgroundColor: const Color(0xFFB91C1C),
          ),
        );
      }
    }
  }

  Future<void> _onCall(ActionRequiredItem item) async {
    final raw = item.clientPhone?.replaceAll(RegExp(r'\s+'), '') ?? '';
    if (raw.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('No phone on file for this item'),
            backgroundColor: Color(0xFF4B5563),
          ),
        );
      }
      return;
    }
    final uri = Uri(scheme: 'tel', path: raw);
    try {
      final ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!ok && mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('Could not start phone app'),
            backgroundColor: Color(0xFFB91C1C),
          ),
        );
      }
    } catch (e, st) {
      if (kDebugMode) {
        _logReminderPopupError(e, st);
      }
    }
  }

  Future<void> _onClosePressed() async {
    await AudioService.stop();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0E0E14),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                'Action Required',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: const Color(0xFFF8FAFC),
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            Flexible(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                shrinkWrap: true,
                itemCount: _items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final item = _items[index];
                  final busy = _busy.contains(item.id);
                  final timeLabel =
                      ReminderItem.formatPopupScheduleLine(item.dueOrScheduleMs);
                  final detail = item.subtitleLine.trim();
                  final sub = detail.isNotEmpty
                      ? '📌 $detail'
                      : (item.amount != null && item.amount! > 0
                          ? _formatInr(item.amount!)
                          : '');
                  return Material(
                    color: _lineBackground(item),
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.iconEmoji,
                                style: const TextStyle(fontSize: 18),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${index + 1}. ${item.titleLine}',
                                      style: TextStyle(
                                        color: _lineColor(item),
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        height: 1.2,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      '🕒 $timeLabel',
                                      style: const TextStyle(
                                        color: Color(0xFF94A3B8),
                                        fontSize: 12,
                                      ),
                                    ),
                                    if (sub.isNotEmpty) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        sub,
                                        style: const TextStyle(
                                          color: Color(0xFFE2E8F0),
                                          fontSize: 12,
                                          height: 1.25,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              _MiniAction(
                                label: 'Done',
                                icon: Icons.check_circle_outline,
                                color: const Color(0xFF22C55E),
                                onPressed: busy
                                    ? null
                                    : () => unawaited(_onDone(item)),
                              ),
                              _MiniAction(
                                label: 'Later',
                                icon: Icons.schedule,
                                color: const Color(0xFFF59E0B),
                                onPressed: busy
                                    ? null
                                    : () => unawaited(_onLater(item)),
                              ),
                              _MiniAction(
                                label: 'Call',
                                icon: Icons.call,
                                color: const Color(0xFF60A5FA),
                                onPressed: busy
                                    ? null
                                    : (item.clientPhone == null || item.clientPhone!.isEmpty
                                        ? null
                                        : () => unawaited(_onCall(item))),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: () => unawaited(_onClosePressed()),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF6366F1),
                  foregroundColor: const Color(0xFFF8FAFC),
                ),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: onPressed == null
            ? const Color(0xFF6B7280)
            : color,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon, size: 16),
      label: Text(
        label,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}
