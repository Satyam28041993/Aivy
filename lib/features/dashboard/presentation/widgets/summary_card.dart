import 'package:flutter/material.dart';

enum SummaryCardVariant { quotation, revenue, followUp, order }

class DashboardSummaryCard extends StatefulWidget {
  const DashboardSummaryCard({
    super.key,
    required this.variant,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
    this.onTap,
  });

  final SummaryCardVariant variant;
  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  State<DashboardSummaryCard> createState() => _DashboardSummaryCardState();
}

class _DashboardSummaryCardState extends State<DashboardSummaryCard> {
  double _scale = 1;

  List<Color> get _innerGradient {
    switch (widget.variant) {
      case SummaryCardVariant.quotation:
        return const [Color(0xFF6D28D9), Color(0xFF4F46E5), Color(0xFF312E81)];
      case SummaryCardVariant.revenue:
        return const [Color(0xFF4338CA), Color(0xFF2563EB), Color(0xFF172554)];
      case SummaryCardVariant.followUp:
        return const [Color(0xFF0E7490), Color(0xFF0D9488), Color(0xFF134E4A)];
      case SummaryCardVariant.order:
        return const [Color(0xFF7C3AED), Color(0xFF4F46E5), Color(0xFF312E81)];
    }
  }

  /// Subtle purple → blue or cyan → teal rim (Jarvis-style holographic edge).
  List<Color> get _rimGradient {
    switch (widget.variant) {
      case SummaryCardVariant.quotation:
      case SummaryCardVariant.revenue:
        return [
          const Color(0xFFC4B5FD).withValues(alpha: 0.55),
          const Color(0xFF60A5FA).withValues(alpha: 0.4),
          const Color(0xFF22D3EE).withValues(alpha: 0.35),
        ];
      case SummaryCardVariant.followUp:
        return [
          const Color(0xFF2DD4BF).withValues(alpha: 0.5),
          const Color(0xFF06B6D4).withValues(alpha: 0.45),
          const Color(0xFF14B8A6).withValues(alpha: 0.4),
        ];
      case SummaryCardVariant.order:
        return [
          const Color(0xFFC4B5FD).withValues(alpha: 0.48),
          const Color(0xFF7C3AED).withValues(alpha: 0.38),
          const Color(0xFF22D3EE).withValues(alpha: 0.32),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const radius = 20.0;

    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.97),
      onTapUp: (_) => setState(() => _scale = 1),
      onTapCancel: () => setState(() => _scale = 1),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: Container(
          constraints: const BoxConstraints(minHeight: 136, minWidth: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              colors: _rimGradient,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: _innerGradient.first.withValues(alpha: 0.45),
                blurRadius: 22,
                spreadRadius: -2,
                offset: const Offset(0, 10),
              ),
              BoxShadow(
                color: const Color(0xFF6366F1).withValues(alpha: 0.18),
                blurRadius: 28,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          padding: const EdgeInsets.all(1.25),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius - 1.25),
              gradient: LinearGradient(
                colors: _innerGradient,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.12),
                            ),
                          ),
                          child: Icon(
                            widget.icon,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        const Spacer(),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      widget.title,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.88),
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.15,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      widget.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.6,
                        fontSize: 26,
                        shadows: [
                          Shadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.78),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
