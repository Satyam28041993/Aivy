import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb, debugPrint;
import 'package:flutter/material.dart';

import '../../../core/firebase/firebase_session.dart';
import '../../integrations/google/google_gmail_read_client.dart';

/// Recent inbox messages (Gmail read-only).
class GmailRecentScreen extends StatefulWidget {
  const GmailRecentScreen({super.key});

  @override
  State<GmailRecentScreen> createState() => _GmailRecentScreenState();
}

class _GmailRecentScreenState extends State<GmailRecentScreen> {
  List<GmailMessageSummary> _rows = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (kIsWeb) {
      setState(() {
        _loading = false;
        _error = 'Gmail sirf Android app par available hai.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await GoogleGmailReadClient.listRecentInbox(maxResults: 25);
      if (!mounted) {
        return;
      }
      setState(() {
        _rows = list;
        _loading = false;
      });
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[Aivy] GmailRecentScreen: $e\n$st');
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gmail (Inbox)'),
        backgroundColor: theme.colorScheme.surface,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              'Sirf padhne ke liye (read-only). Naya mail bhejne ke liye chat mein '
              '`… ko mail bhejo` wala flow use karein.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final ok = await FirebaseSession.ensureWorkspaceScopes();
                      if (!context.mounted) {
                        return;
                      }
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            ok
                                ? 'Permissions OK — dubara load.'
                                : 'Permission nahi mili.',
                          ),
                        ),
                      );
                      await _load();
                    },
                    child: const Text('Allow Google extras'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                ? Center(
                    child: Text(
                      _error == null
                          ? 'Inbox khaali ya load nahi ho paya.'
                          : 'Neeche error dekhein.',
                      style: theme.textTheme.bodyLarge,
                    ),
                  )
                : ListView.separated(
                    itemCount: _rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final m = _rows[i];
                      return ListTile(
                        title: Text(
                          m.subject,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${m.from}\n${m.snippet}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                        isThreeLine: true,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
