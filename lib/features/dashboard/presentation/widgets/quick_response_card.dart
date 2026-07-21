import 'package:flutter/material.dart';

class QuickResponseCard extends StatelessWidget {
  const QuickResponseCard({
    super.key,
    required this.replyText,
    this.actionLine,
    required this.onViewDetails,
    this.isBusy = false,
  });

  final String replyText;
  final String? actionLine;
  final VoidCallback onViewDetails;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF1E1B4B).withValues(alpha: 0.92),
              const Color(0xFF0F172A).withValues(alpha: 0.94),
            ],
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.1),
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6366F1).withValues(alpha: 0.12),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isBusy) ...[
              Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Working on it…',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ] else ...[
              if (actionLine != null && actionLine!.isNotEmpty) ...[
                Text(
                  actionLine!,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: const Color(0xFF34D399),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                replyText,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.92),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onViewDetails,
                  icon: const Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 18,
                    color: Color(0xFFA78BFA),
                  ),
                  label: const Text('View details'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFC4B5FD),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
