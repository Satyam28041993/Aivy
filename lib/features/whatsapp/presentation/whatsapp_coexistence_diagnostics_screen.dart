import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/whatsapp_coexistence_diagnostics_repository.dart';

/// Debug-only coexistence webhook diagnostics (Phase 3.5 observability).
class WhatsappCoexistenceDiagnosticsScreen extends StatelessWidget {
  const WhatsappCoexistenceDiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = WhatsappCoexistenceDiagnosticsRepository();
    final dateFmt = DateFormat.yMMMd().add_jms();

    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsApp Coexistence Diagnostics'),
        backgroundColor: theme.colorScheme.surface,
      ),
      body: StreamBuilder<WhatsappCoexistenceDiagnosticsSnapshot>(
        stream: repo.watchDiagnostics(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data =
              snap.data ??
              const WhatsappCoexistenceDiagnosticsSnapshot();
          final summary = data.summary;
          final totals = summary['totals'] is Map
              ? Map<String, dynamic>.from(summary['totals'] as Map)
              : const <String, dynamic>{};

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Separate coexistence webhook storage — does not affect inbox '
                'or legacy messaging.',
                style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
              ),
              const SizedBox(height: 16),
              _InfoCard(
                title: 'Processing status',
                lines: [
                  'Status: ${data.lastProcessingStatus.isEmpty ? '—' : data.lastProcessingStatus}',
                  _formatMs(summary['lastWebhookProcessedAtMs'], dateFmt),
                  'Payload hash: ${_short('${summary['lastWebhookPayloadHash'] ?? ''}')}',
                ],
              ),
              const SizedBox(height: 12),
              _InfoCard(
                title: 'Totals',
                lines: [
                  'History created: ${totals['historyRecordsCreated'] ?? 0}',
                  'History duplicates: ${totals['historyDuplicatesSkipped'] ?? 0}',
                  'SMB sync created: ${totals['smbSyncRecordsCreated'] ?? 0}',
                  'SMB sync duplicates: ${totals['smbSyncDuplicatesSkipped'] ?? 0}',
                  'Echo created: ${totals['echoRecordsCreated'] ?? 0}',
                  'Echo duplicates: ${totals['echoDuplicatesSkipped'] ?? 0}',
                ],
              ),
              const SizedBox(height: 12),
              _InfoCard(
                title: 'Last history event',
                lines: _recordLines(data.lastHistory, dateFmt),
              ),
              const SizedBox(height: 12),
              _InfoCard(
                title: 'Last app state sync',
                lines: _recordLines(data.lastSmbSync, dateFmt),
              ),
              const SizedBox(height: 12),
              _InfoCard(
                title: 'Last message echo',
                lines: _recordLines(data.lastEcho, dateFmt),
              ),
              const SizedBox(height: 12),
              _InfoCard(
                title: 'Parse errors',
                lines: data.parseErrors.isEmpty
                    ? const ['None recorded']
                    : data.parseErrors,
              ),
            ],
          );
        },
      ),
    );
  }

  static String _formatMs(Object? raw, DateFormat fmt) {
    if (raw is num && raw > 0) {
      return 'Processed: ${fmt.format(DateTime.fromMillisecondsSinceEpoch(raw.toInt()))}';
    }
    return 'Processed: —';
  }

  static String _short(String value) {
    if (value.length <= 12) {
      return value.isEmpty ? '—' : value;
    }
    return '${value.substring(0, 12)}…';
  }

  static List<String> _recordLines(
    Map<String, dynamic>? record,
    DateFormat fmt,
  ) {
    if (record == null || record.isEmpty) {
      return const ['None yet'];
    }
    return [
      'Record: ${_short('${record['id'] ?? record['idempotencyKey'] ?? ''}')}',
      'WABA: ${record['wabaId'] ?? '—'}',
      'Phone Number ID: ${record['phoneNumberId'] ?? '—'}',
      'Status: ${record['processingStatus'] ?? '—'}',
      _formatMs(record['lastSeenAtMs'], fmt),
      'Deliveries: ${record['deliveryCount'] ?? '—'}',
    ];
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.lines});

  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          ...lines.map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                line,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
