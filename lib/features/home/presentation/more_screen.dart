import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../core/auth/aivy_auth_scope.dart';
import '../../../core/firebase/firebase_session.dart';
import '../../integrations/data/google_integration_store.dart';
import '../../integrations/presentation/gmail_recent_screen.dart';
import '../../../core/notifications/notification_health_screen.dart';
import '../../../core/notifications/notifications_screen.dart';
import '../../chat/data/chat_repository.dart';
import '../../chat/models/chat_session.dart';
import '../../contacts/presentation/contacts_list_screen.dart';
import 'data_management_screen.dart';

class MoreScreen extends StatefulWidget {
  const MoreScreen({super.key, required this.userId});

  final String userId;

  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {
  late final ChatRepository _repo = ChatRepository();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = AivyAuthScope.of(context);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'More',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Account',
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.person_outline_rounded),
          title: Text(auth.displayName ?? 'Signed in'),
          subtitle: Text(
            auth.email ?? auth.uid ?? '',
            style: theme.textTheme.bodySmall,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.fingerprint_rounded),
          title: const Text('User id'),
          subtitle: SelectableText(
            auth.uid ?? '—',
            style: theme.textTheme.bodySmall,
          ),
        ),
        const Divider(height: 24),
        Text(
          'Google for Aivy',
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          kIsWeb
              ? 'Contacts, Calendar, Sheets, Gmail — use the Android app to grant '
                  'Google permissions.'
              : 'Contacts, Calendar, Sheets, Gmail (read + send) — ek extra '
                  'permission screen after sign-in.',
          style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
        ),
        const SizedBox(height: 8),
        if (!kIsWeb)
          ListTile(
            leading: const Icon(Icons.link_rounded),
            title: const Text('Allow Google extras'),
            subtitle: const Text(
              'Calendar, Gmail inbox + send, Sheets, Google contact search',
            ),
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              final ok = await FirebaseSession.ensureWorkspaceScopes();
              if (!context.mounted) {
                return;
              }
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    ok
                        ? 'Google permissions saved.'
                        : 'Cancelled or not granted — try again from here.',
                  ),
                ),
              );
            },
          ),
        if (!kIsWeb)
          ListTile(
            leading: const Icon(Icons.mail_outline_rounded),
            title: const Text('Gmail inbox (read-only)'),
            subtitle: const Text('Recent messages from the signed-in Google account'),
            onTap: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (context) => const GmailRecentScreen(),
                ),
              );
            },
          ),
        StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('users')
              .doc(widget.userId)
              .collection('meta')
              .doc('google_prefs')
              .snapshots(),
          builder: (context, snap) {
            final id =
                '${snap.data?.data()?['defaultSpreadsheetId'] ?? ''}'.trim();
            return ListTile(
              leading: const Icon(Icons.table_chart_outlined),
              title: const Text('Default Google Sheet ID'),
              subtitle: Text(
                id.isEmpty
                    ? 'Not set — chat: sheet row: a, b, c'
                    : id,
                style: theme.textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () async {
                final ctrl = TextEditingController(text: id);
                final saved = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Default Sheet ID'),
                    content: TextField(
                      controller: ctrl,
                      decoration: const InputDecoration(
                        hintText: 'URL ke /d/ aur /edit/ ke beech',
                      ),
                      autofocus: true,
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () =>
                            Navigator.pop(ctx, ctrl.text.trim()),
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                );
                if (!context.mounted || saved == null) {
                  return;
                }
                await GoogleIntegrationStore().setDefaultSpreadsheetId(
                  widget.userId,
                  saved,
                );
                if (!context.mounted) {
                  return;
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Sheet ID saved.')),
                );
              },
            );
          },
        ),
        const Divider(height: 32),
        Text(
          'Live from Firestore',
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Chat threads and meeting sessions update in real time while you '
          'use the app on any device with the same Google account.',
          style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
        ),
        const SizedBox(height: 12),
        ListTile(
          leading: const Icon(Icons.notifications_active_outlined),
          title: const Text('Notification health'),
          subtitle: const Text(
            'Why a reminder did or did not reach your phone — and a test',
          ),
          onTap: () {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (context) =>
                    NotificationHealthScreen(userId: widget.userId),
              ),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.notifications_outlined),
          title: const Text('In-app notifications'),
          subtitle: const Text('Payment reminders and follow-ups from the server'),
          onTap: () {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (context) =>
                    NotificationsScreen(userId: widget.userId),
              ),
            );
          },
        ),
        StreamBuilder<List<ChatSession>>(
          stream: _repo.watchChats(widget.userId),
          builder: (context, snap) {
            final n = snap.data?.length ?? 0;
            return ListTile(
              leading: const Icon(Icons.chat_outlined),
              title: const Text('Chat sessions'),
              subtitle: Text(
                snap.connectionState == ConnectionState.waiting && !snap.hasData
                    ? 'Loading…'
                    : '$n threads',
              ),
            );
          },
        ),
        StreamBuilder(
          stream: _repo.watchMeetingSessions(widget.userId, limit: 20),
          builder: (context, snap) {
            final list = snap.data ?? const [];
            return ListTile(
              leading: const Icon(Icons.mic_none_rounded),
              title: const Text('Meeting sessions'),
              subtitle: Text(
                snap.connectionState == ConnectionState.waiting && !snap.hasData
                    ? 'Loading…'
                    : list.isEmpty
                    ? 'None yet — record a meeting from Home'
                    : '${list.length} recent (live)',
              ),
            );
          },
        ),
        StreamBuilder(
          stream: _repo.watchUserMemory(widget.userId, limit: 20),
          builder: (context, snap) {
            final list = snap.data ?? const [];
            return ListTile(
              leading: const Icon(Icons.psychology_outlined),
              title: const Text('Memory index'),
              subtitle: Text(
                snap.connectionState == ConnectionState.waiting && !snap.hasData
                    ? 'Loading…'
                    : '${list.length} entries (live)',
              ),
            );
          },
        ),
        const Divider(height: 32),
        ListTile(
          leading: Icon(Icons.logout_rounded, color: theme.colorScheme.error),
          title: Text(
            'Sign out',
            style: TextStyle(color: theme.colorScheme.error),
          ),
          onTap: () async {
            await auth.signOut();
          },
        ),
        ListTile(
          leading: const Icon(Icons.cloud_outlined),
          title: const Text('Cloud data'),
          subtitle: const Text('Delete chats, orders & reminders from Firebase'),
          onTap: () {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (context) => const DataManagementScreen(),
              ),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.contacts_outlined),
          title: const Text('Contacts'),
          subtitle: const Text('CRM list aur tags'),
          onTap: () {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (context) => const ContactsListScreen(),
              ),
            );
          },
        ),
      ],
    );
  }
}
