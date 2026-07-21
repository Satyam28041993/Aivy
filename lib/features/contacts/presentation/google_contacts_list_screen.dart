import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb, debugPrint;
import 'package:flutter/material.dart';

import '../../../core/firebase/firebase_session.dart';
import '../data/google_people_contacts_client.dart';
import '../models/aivy_contact.dart';

/// Read-only list from Google People API (device Google account).
class GoogleContactsListScreen extends StatefulWidget {
  const GoogleContactsListScreen({super.key, required this.ownerUid});

  final String ownerUid;

  @override
  State<GoogleContactsListScreen> createState() => _GoogleContactsListScreenState();
}

class _GoogleContactsListScreenState extends State<GoogleContactsListScreen> {
  final _search = TextEditingController();
  List<AivyContact> _all = const [];
  bool _loading = true;
  String? _error;
  String _q = '';
  int _totalMerged = 0;
  int _connectionsRows = 0;
  int _otherRows = 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (kIsWeb) {
      setState(() {
        _loading = false;
        _error = 'Google Contacts sirf Android app par available hain.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detailed = await GooglePeopleContactsClient.loadAllConnectionsDetailed(
        ownerUid: widget.ownerUid,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _all = detailed.contacts;
        _totalMerged = detailed.contacts.length;
        _connectionsRows = detailed.connectionsSourceRows;
        _otherRows = detailed.otherContactsSourceRows;
        _loading = false;
      });
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[Aivy] GoogleContactsListScreen: $e\n$st');
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

  List<AivyContact> get _filtered {
    final t = _q.trim().toLowerCase();
    if (t.isEmpty) {
      return _all;
    }
    return _all
        .where(
          (c) =>
              c.name.toLowerCase().contains(t) ||
              c.phone.contains(t) ||
              c.email.toLowerCase().contains(t),
        )
        .toList(growable: false);
  }

  String _avatarGlyph(String name) {
    if (name.isEmpty) {
      return '?';
    }
    return String.fromCharCode(name.runes.first);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Google Contacts'),
            if (!_loading && _error == null)
              Text(
                _q.isEmpty
                    ? '$_totalMerged saved in app · Google rows: '
                        '$_connectionsRows contacts + $_otherRows other'
                    : 'Dikh rahe: ${_filtered.length} / $_totalMerged',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ],
        ),
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
              'Ye list Google People API se aati hai (saari pages + Other contacts). '
              'Phone dedupe se count device sync (2561) se thoda kam ho sakta hai.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: 'Search name, phone, email…',
                prefixIcon: const Icon(Icons.search_rounded),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (_error != null && _error!.contains('Allow Google'))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: FilledButton.tonal(
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
                            ? 'Permissions OK — dubara load ho raha hai.'
                            : 'Permission nahi mili.',
                      ),
                    ),
                  );
                  await _load();
                },
                child: const Text('Allow Google extras'),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _filtered.isEmpty
                ? Center(
                    child: Text(
                      _q.isEmpty
                          ? 'Koi contact nahi mila.\nGoogle Contacts mein naam + '
                                'number save hon, aur More → Allow Google extras.'
                          : 'Koi match nahi "$_q"',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge,
                    ),
                  )
                : ListView.separated(
                    itemCount: _filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final c = _filtered[i];
                      final sub = <String>[
                        if (c.phone.isNotEmpty) c.phone else 'Phone: —',
                        if (c.email.isNotEmpty) c.email,
                      ].join(' · ');
                      return ListTile(
                        title: Text(c.name),
                        subtitle: Text(
                          sub,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        leading: CircleAvatar(
                          child: Text(_avatarGlyph(c.name)),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
