import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../core/config/meta_whatsapp_runtime_config.dart';
import '../onboarding/meta_embedded_signup_result.dart';
import '../onboarding/whatsapp_onboarding_repository.dart';
import 'connect_whatsapp_button.dart';
import 'whatsapp_coexistence_diagnostics_screen.dart';

/// Standalone coexistence onboarding entry point — isolated from legacy Cloud API UI.
class WhatsAppConnectScreen extends StatefulWidget {
  const WhatsAppConnectScreen({super.key});

  @override
  State<WhatsAppConnectScreen> createState() => _WhatsAppConnectScreenState();
}

class _WhatsAppConnectScreenState extends State<WhatsAppConnectScreen> {
  final _repository = WhatsappOnboardingRepository();
  MetaWhatsappRuntimeConfig? _runtimeConfig;
  MetaEmbeddedSignupResult? _lastLaunch;
  WhatsappConnectionMetadata? _lastConnection;
  bool _configLoading = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final cfg = await _repository.fetchClientConfig();
    if (!mounted) {
      return;
    }
    setState(() {
      _runtimeConfig = cfg;
      _configLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final configured = _runtimeConfig?.isComplete == true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect WhatsApp Business'),
        backgroundColor: theme.colorScheme.surface,
        actions: [
          IconButton(
            icon: const Icon(Icons.analytics_outlined),
            tooltip: 'View Coexistence Diagnostics',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const WhatsappCoexistenceDiagnosticsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Link your WhatsApp Business app number through Meta Embedded Signup '
            '(Tech Provider coexistence). Configuration is loaded from the backend '
            'so production does not depend on app rebuilds.',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
          const SizedBox(height: 16),
          if (_configLoading)
            const LinearProgressIndicator()
          else if (!configured)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.colorScheme.error),
              ),
              child: Text(
                'Meta client config is incomplete. An admin must seed '
                'app_config/meta_whatsapp or set local META_* dart-defines for dev.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (!_configLoading && configured) ...[
            _ConfigSummary(config: _runtimeConfig!),
            const SizedBox(height: 16),
          ],
          ConnectWhatsAppButton(
            repository: _repository,
            onCompleted: (result) {
              setState(() => _lastLaunch = result);
            },
            onConnectionStored: (connection) {
              setState(() => _lastConnection = connection);
            },
          ),
          const SizedBox(height: 24),
          Text(
            'Phase 2 exchanges the OAuth code on the backend and stores the '
            'business token in Secret Manager. Firestore keeps metadata only. '
            'Existing inbox and messaging remain on the legacy path until Phase 4.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          if (uid != null) ...[
            const SizedBox(height: 24),
            Text(
              'Saved connection',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(uid)
                  .collection('meta')
                  .doc('whatsapp_connection')
                  .snapshots(),
              builder: (context, snap) {
                final data = snap.data?.data();
                if (data == null) {
                  return Text(
                    'No connection saved yet.',
                    style: theme.textTheme.bodySmall,
                  );
                }
                return _MetadataSummary(data: data);
              },
            ),
          ],
          if (_lastLaunch != null) ...[
            const SizedBox(height: 24),
            Text(
              'Last launch session',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            _SessionSummary(result: _lastLaunch!),
          ],
          if (_lastConnection != null) ...[
            const SizedBox(height: 16),
            _ConnectionSummary(connection: _lastConnection!),
          ],
          const SizedBox(height: 24),
          OutlinedButton.icon(
            icon: const Icon(Icons.analytics_outlined),
            label: const Text('View Webhook Diagnostics & Logs'),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) =>
                      const WhatsappCoexistenceDiagnosticsScreen(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ConfigSummary extends StatelessWidget {
  const _ConfigSummary({required this.config});

  final MetaWhatsappRuntimeConfig config;

  static String _mask(String value) {
    final v = value.trim();
    if (v.length <= 8) {
      return v;
    }
    return '${v.substring(0, 8)}…';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'Config source: ${config.source.name}\n'
        'App ID: ${config.appId}\n'
        'Embedded Signup config: ${_mask(config.embeddedSignupConfigId)}',
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
      ),
    );
  }
}

class _MetadataSummary extends StatelessWidget {
  const _MetadataSummary({required this.data});

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = [
      'WABA: ${data['wabaId'] ?? '—'}',
      'Phone Number ID: ${data['phoneNumberId'] ?? '—'}',
      'Display: ${data['displayPhoneNumber'] ?? '—'}',
      'Status: ${data['connectionStatus'] ?? '—'}',
      'History sync: ${data['historySyncStatus'] ?? '—'}',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: SelectableText(
        lines.join('\n'),
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
      ),
    );
  }
}

class _ConnectionSummary extends StatelessWidget {
  const _ConnectionSummary({required this.connection});

  final WhatsappConnectionMetadata connection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.green),
      ),
      child: SelectableText(
        'Connected\n'
        'WABA: ${connection.wabaId}\n'
        'Phone Number ID: ${connection.phoneNumberId}\n'
        'Display: ${connection.displayPhoneNumber.isEmpty ? '—' : connection.displayPhoneNumber}\n'
        'Token ref: ${connection.tokenSecretRef.isEmpty ? '—' : '${connection.tokenSecretRef.split('/').last}…'}',
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
      ),
    );
  }
}

class _SessionSummary extends StatelessWidget {
  const _SessionSummary({required this.result});

  final MetaEmbeddedSignupResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = <String>[
      'Status: ${result.status.name}',
      if (result.eventName != null) 'Event: ${result.eventName}',
      if (result.oauthCode != null)
        'OAuth code: ${result.oauthCode!.length > 8 ? '${result.oauthCode!.substring(0, 8)}…' : result.oauthCode}',
      if (result.eventData != null && result.eventData!.isNotEmpty)
        'Event data keys: ${result.eventData!.keys.join(', ')}',
      if (result.errorMessage != null) 'Message: ${result.errorMessage}',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: SelectableText(
        lines.join('\n'),
        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
      ),
    );
  }
}
