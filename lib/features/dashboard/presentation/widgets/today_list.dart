import 'package:flutter/material.dart';

/// Row model for "Today at a glance".
class TodayGlanceRow {
  const TodayGlanceRow({
    required this.title,
    required this.timeLabel,
    required this.indicatorColor,
  });

  final String title;
  final String timeLabel;
  final Color indicatorColor;
}

class TodayAtGlanceList extends StatelessWidget {
  const TodayAtGlanceList({
    super.key,
    required this.todayReminders,
    required this.overdueFollowUps,
  });

  final List<TodayGlanceRow> todayReminders;
  final List<TodayGlanceRow> overdueFollowUps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const radius = 20.0;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius + 1),
        gradient: LinearGradient(
          colors: [
            const Color(0xFF818CF8).withValues(alpha: 0.35),
            const Color(0xFF22D3EE).withValues(alpha: 0.28),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6366F1).withValues(alpha: 0.2),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(1.25),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF141522).withValues(alpha: 0.98),
              const Color(0xFF0F1118).withValues(alpha: 0.98),
            ],
          ),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'TODAY AT A GLANCE',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            if (todayReminders.isNotEmpty) ...[
              Text(
                'Today reminders',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: const Color(0xFF94A3B8),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              ...todayReminders.map((r) => _GlanceRow(data: r)),
              const SizedBox(height: 18),
            ],
            if (overdueFollowUps.isNotEmpty) ...[
              Text(
                'Overdue follow-ups',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: const Color(0xFF94A3B8),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              ...overdueFollowUps.map((r) => _GlanceRow(data: r)),
            ],
            if (todayReminders.isEmpty && overdueFollowUps.isEmpty)
              Text(
                'Nothing scheduled for today. You are all caught up.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GlanceRow extends StatelessWidget {
  const _GlanceRow({required this.data});

  final TodayGlanceRow data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(
              color: data.indicatorColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: data.indicatorColor.withValues(alpha: 0.55),
                  blurRadius: 8,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              data.title,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            data.timeLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
