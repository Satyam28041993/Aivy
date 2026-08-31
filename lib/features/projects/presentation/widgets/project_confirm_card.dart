import 'package:flutter/material.dart';

import '../../utils/project_confirm.dart';

class ProjectConfirmCard extends StatelessWidget {
  const ProjectConfirmCard({
    super.key,
    required this.projectName,
    required this.client,
    required this.items,
  });

  final String projectName;
  final String client;
  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF12141C),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            projectName.isEmpty ? 'Project' : projectName,
            style: theme.textTheme.titleSmall?.copyWith(
              color: const Color(0xFFE2E8F0),
              fontWeight: FontWeight.w800,
            ),
          ),
          if (client.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              client,
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF94A3B8),
              ),
            ),
          ],
          const SizedBox(height: 10),
          for (final item in items) _ItemRow(item: item),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});

  final Map<String, dynamic> item;

  Color get _statusColor {
    switch ((item['status'] as String? ?? '').trim()) {
      case 'waiting_on_them':
        return const Color(0xFFF97316);
      case 'done':
        return const Color(0xFF22C55E);
      case 'cancelled':
        return const Color(0xFF64748B);
      default:
        return const Color(0xFF22D3EE);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = (item['title'] as String? ?? '').trim();
    final kind = (item['kind'] as String? ?? 'general').trim();
    final status = projectItemStatusLabel(
      (item['status'] as String? ?? 'pending').trim(),
    );
    final due = (item['dueLabel'] as String? ?? '').trim();
    final who = (item['waitingOn'] as String? ?? '').trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(
              color: _statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              [
                '[$kind] $title',
                status,
                if (due.isNotEmpty) due,
                if (who.isNotEmpty) who,
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFFE2E8F0),
                    height: 1.35,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
