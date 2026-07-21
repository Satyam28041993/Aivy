import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/client_insights_summary.dart';

/// Phase 3: quick business snapshot at top of home (driven by `meta/client_insights`).
class ClientInsightsStrip extends StatelessWidget {
  const ClientInsightsStrip({
    super.key,
    required this.data,
  });

  final ClientInsightsSummary data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currency = NumberFormat.currency(
      locale: 'en_IN',
      symbol: '₹',
      decimalDigits: 0,
    );
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A24),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFF6366F1).withValues(alpha: 0.35),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.insights_rounded,
                  size: 18,
                  color: const Color(0xFFA78BFA).withValues(alpha: 0.95),
                ),
                const SizedBox(width: 8),
                Text(
                  'TODAY / BUSINESS PULSE',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: const Color(0xFF94A3B8),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              data.oneLiner.isNotEmpty
                  ? data.oneLiner
                  : 'Loading business snapshot…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFE2E8F0),
                height: 1.35,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Chip(
                  label: 'Total due',
                  value: currency.format(data.totalDue),
                ),
                _Chip(
                  label: 'Overdue',
                  value: currency.format(data.overdueAmount),
                ),
                _Chip(
                  label: 'Follow-ups',
                  value: '${data.todayDueCount}',
                ),
                _Chip(
                  label: 'Risky',
                  value: '${data.riskyClientsCount}',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFF334155).withValues(alpha: 0.8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF94A3B8),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFFF1F5F9),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
