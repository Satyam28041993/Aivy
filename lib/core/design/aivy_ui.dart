import 'package:flutter/material.dart';

/// The visual language for Aivy's business screens.
///
/// One file rather than a theme extension, because these screens are the only
/// consumers and a token you can read the value of beats a token you have to
/// trace through three layers of inherited widgets.
///
/// The palette is dark on purpose. The Aivy tab — the screen the user actually
/// lives in — is near-black, and an app that flips to white on the next tab
/// reads as two apps stitched together. Dark also lets one accent colour carry
/// meaning: on a light ground every card competes, on this ground only the
/// coloured ones speak.
///
/// Colour carries meaning here, never decoration:
///   danger  — money already late, or a deadline missed
///   warn    — needs a decision today
///   ok      — settled, done, on track
///   brand   — Aivy herself, and anything that opens her
class AivyUi {
  AivyUi._();

  // --- ground ---------------------------------------------------------------
  /// Page background. Slightly blue-black rather than pure black: pure black
  /// makes elevation impossible to read on OLED.
  static const Color bg = Color(0xFF080B12);
  static const Color surface = Color(0xFF11151F);
  static const Color surfaceHigh = Color(0xFF171C28);
  static const Color line = Color(0xFF232A38);

  // --- ink ------------------------------------------------------------------
  static const Color ink = Color(0xFFF3F5F9);
  static const Color inkSoft = Color(0xFF9AA6BC);
  static const Color inkFaint = Color(0xFF5D6880);

  // --- meaning --------------------------------------------------------------
  static const Color brand = Color(0xFF8B7BFF);
  static const Color brandDim = Color(0xFF3A3468);
  static const Color danger = Color(0xFFFF6B6B);
  static const Color warn = Color(0xFFFFB454);
  static const Color ok = Color(0xFF4ADE80);
  static const Color info = Color(0xFF56CCF2);

  // --- rhythm ---------------------------------------------------------------
  static const double gap = 14;
  static const double pad = 16;
  static const double radius = 18;
  static const double radiusSm = 12;

  /// Numbers line up in columns only with tabular figures — without this a
  /// list of amounts visibly wobbles.
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  static TextStyle display(BuildContext c) =>
      Theme.of(c).textTheme.headlineMedium!.copyWith(
            color: ink,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.8,
            fontFeatures: tabular,
          );

  static TextStyle title(BuildContext c) =>
      Theme.of(c).textTheme.titleMedium!.copyWith(
            color: ink,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          );

  static TextStyle body(BuildContext c) =>
      Theme.of(c).textTheme.bodyMedium!.copyWith(color: ink, height: 1.35);

  static TextStyle soft(BuildContext c) =>
      Theme.of(c).textTheme.bodySmall!.copyWith(color: inkSoft, height: 1.35);

  /// Small all-caps label above a group. Sparingly — it is loud for its size.
  static TextStyle label(BuildContext c) =>
      Theme.of(c).textTheme.labelSmall!.copyWith(
            color: inkFaint,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          );

  static String inr(num amount) {
    final v = amount.abs().round();
    if (v >= 10000000) {
      return '₹${(v / 10000000).toStringAsFixed(v % 10000000 == 0 ? 0 : 1)}Cr';
    }
    if (v >= 100000) {
      return '₹${(v / 100000).toStringAsFixed(v % 100000 == 0 ? 0 : 1)}L';
    }
    if (v >= 1000) {
      return '₹${(v / 1000).toStringAsFixed(v % 1000 == 0 ? 0 : 1)}k';
    }
    return '₹$v';
  }

  /// Full rupee figure with Indian grouping, for places where precision beats
  /// brevity — a payment row, not a headline tile.
  static String inrExact(num amount) {
    final s = amount.abs().round().toString();
    if (s.length <= 3) {
      return '₹$s';
    }
    final last3 = s.substring(s.length - 3);
    var rest = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) {
      parts.insert(0, rest);
    }
    return '₹${parts.join(',')},$last3';
  }
}

/// The one card shape the business screens use.
///
/// [accent] tints the border and lays a hairline down the left edge — enough to
/// mark a card as urgent without turning the screen into a traffic light.
class AivyCard extends StatelessWidget {
  const AivyCard({
    super.key,
    required this.child,
    this.accent,
    this.onTap,
    this.padding = const EdgeInsets.all(AivyUi.pad),
  });

  final Widget child;
  final Color? accent;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final a = accent;
    final card = Container(
      decoration: BoxDecoration(
        color: AivyUi.surface,
        borderRadius: BorderRadius.circular(AivyUi.radius),
        border: Border.all(
          color: a == null ? AivyUi.line : a.withValues(alpha: 0.35),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AivyUi.radius - 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (a != null) Container(width: 3, color: a),
            Expanded(child: Padding(padding: padding, child: child)),
          ],
        ),
      ),
    );
    if (onTap == null) {
      return card;
    }
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AivyUi.radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(AivyUi.radius),
        onTap: onTap,
        child: card,
      ),
    );
  }
}

/// A heading with an optional count and trailing action.
class AivySectionHeader extends StatelessWidget {
  const AivySectionHeader({
    super.key,
    required this.title,
    this.count,
    this.action,
    this.onAction,
  });

  final String title;
  final int? count;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Row(
        children: [
          Text(title.toUpperCase(), style: AivyUi.label(context)),
          if (count != null && count! > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: AivyUi.surfaceHigh,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$count',
                style: AivyUi.label(context).copyWith(
                  color: AivyUi.inkSoft,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
          const Spacer(),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              child: Text(
                action!,
                style: AivyUi.label(context).copyWith(
                  color: AivyUi.brand,
                  letterSpacing: 0.3,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Small status chip — "Overdue", "Aaj", "3 din baaki".
class AivyPill extends StatelessWidget {
  const AivyPill(this.text, {super.key, this.color = AivyUi.inkSoft, this.icon});

  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// What a section says when it has nothing to say. Deliberately calm — an
/// empty list is usually good news here, not a failure.
class AivyEmpty extends StatelessWidget {
  const AivyEmpty(this.message, {super.key, this.icon = Icons.check_rounded});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AivyUi.inkFaint),
        const SizedBox(width: 10),
        Expanded(child: Text(message, style: AivyUi.soft(context))),
      ],
    );
  }
}

/// A thin proportional bar — used where a number alone hides the shape of
/// things, like which client holds most of the outstanding money.
class AivyBar extends StatelessWidget {
  const AivyBar({super.key, required this.fraction, required this.color});

  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        value: fraction.clamp(0.02, 1.0),
        minHeight: 5,
        backgroundColor: AivyUi.surfaceHigh,
        valueColor: AlwaysStoppedAnimation<Color>(color),
      ),
    );
  }
}
