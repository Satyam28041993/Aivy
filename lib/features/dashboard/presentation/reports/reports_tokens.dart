import 'package:flutter/material.dart';

/// Soft semantic accents for Reports — aligned with [ColorScheme], not loud
/// full-bleed gradients.
class ReportsTokens {
  ReportsTokens._();

  static Color tintHeader(BuildContext context, Color accent) {
    final base = Theme.of(context).colorScheme.surface;
    return Color.alphaBlend(accent.withValues(alpha: 0.09), base);
  }

  static Color overdue(BuildContext context) =>
      Theme.of(context).colorScheme.error;

  static Color overdueSoft(BuildContext context) =>
      Theme.of(context).colorScheme.errorContainer;

  static Color dueToday(BuildContext context) =>
      const Color(0xFFC2410C); // warm amber, readable on light

  static Color dueTodaySoft(BuildContext context) =>
      const Color(0xFFFFF7ED);

  static Color success(BuildContext context) =>
      const Color(0xFF059669);

  static Color muted(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant;

  static Color accentPrimary(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  static Color accentSecondary(BuildContext context) =>
      Theme.of(context).colorScheme.tertiary;
}
