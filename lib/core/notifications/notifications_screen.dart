import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../firebase/aivy_callables.dart';
import 'in_app_notification_item.dart';
import 'in_app_notifications_repository.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key, required this.userId});

  final String userId;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final InAppNotificationsRepository _repo = InAppNotificationsRepository();
  final AivyCallables _aivy = AivyCallables();
  static final _timeFmt = DateFormat('d MMM · hh:mm a');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                await _aivy.markNotificationRead(markAllRead: true);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('All marked as read')),
                  );
                }
              } catch (e) {
                if (kDebugMode) {
                  debugPrint('markAllRead failed: $e');
                }
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Could not mark all as read — try again'),
                    ),
                  );
                }
              }
            },
            child: const Text('Mark all read'),
          ),
        ],
      ),
      body: StreamBuilder<int>(
        stream: _repo.watchUnreadCount(widget.userId),
        builder: (context, countSnap) {
          final n = countSnap.data ?? 0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (n > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '$n unread',
                    style: Theme.of(
                      context,
                    ).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              Expanded(
                child: StreamBuilder<List<InAppNotificationItem>>(
                  stream: _repo.watchNotifications(widget.userId),
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Center(
                        child: Text('Could not load: ${snap.error}'),
                      );
                    }
                    if (snap.connectionState == ConnectionState.waiting &&
                        !snap.hasData) {
                      return const Center(
                        child: CircularProgressIndicator(),
                      );
                    }
                    final list = snap.data ?? const [];
                    if (list.isEmpty) {
                      return const Center(
                        child: Text('No notifications yet.'),
                      );
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final it = list[i];
                        final subtitle = it.createdAtMs > 0
                            ? _timeFmt.format(
                                DateTime.fromMillisecondsSinceEpoch(
                                  it.createdAtMs,
                                ),
                              )
                            : '';
                        return Card(
                          elevation: 0,
                          child: ListTile(
                            title: Text(
                              it.title.isEmpty
                                  ? 'Notification'
                                  : it.title,
                              style: TextStyle(
                                fontWeight: it.read
                                    ? FontWeight.w500
                                    : FontWeight.w700,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (it.message.isNotEmpty)
                                  Text(
                                    it.message,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                if (subtitle.isNotEmpty)
                                  Text(
                                    subtitle,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                              ],
                            ),
                            isThreeLine: it.message.isNotEmpty,
                            trailing: it.read
                                ? null
                                : const Icon(Icons.fiber_new_rounded, size: 20),
                            onTap: it.read
                                ? null
                                : () async {
                                    try {
                                      await _aivy.markNotificationRead(
                                        notificationId: it.id,
                                      );
                                    } catch (e) {
                                      if (kDebugMode) {
                                        debugPrint('mark read: $e');
                                      }
                                    }
                                  },
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
