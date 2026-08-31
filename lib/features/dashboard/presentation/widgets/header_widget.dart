import 'package:flutter/material.dart';

/// Top row: branding, optional projects action, notifications, profile.
class DashboardHeader extends StatelessWidget {
  const DashboardHeader({
    super.key,
    this.onProjectsPressed,
    this.onNotificationsPressed,
    this.onProfilePressed,
    this.hasNotificationDot = true,
  });

  final VoidCallback? onProjectsPressed;
  final VoidCallback? onNotificationsPressed;
  final VoidCallback? onProfilePressed;
  final bool hasNotificationDot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (bounds) => const LinearGradient(
                    colors: [
                      Color(0xFFA78BFA),
                      Color(0xFF60A5FA),
                      Color(0xFF22D3EE),
                    ],
                  ).createShader(bounds),
                  child: Text(
                    'Aivy',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.6,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Your AI Business Assistant',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                    letterSpacing: 0.15,
                  ),
                ),
              ],
            ),
          ),
          if (onProjectsPressed != null)
            IconButton(
              onPressed: onProjectsPressed,
              tooltip: 'Projects',
              icon: const Icon(Icons.account_tree_outlined),
            ),
          IconButton(
            onPressed: onNotificationsPressed,
            tooltip: 'Notifications',
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.notifications_outlined),
                if (hasNotificationDot)
                  Positioned(
                    right: 0,
                    top: 2,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: const Color(0xFF22D3EE),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(
                              0xFF22D3EE,
                            ).withValues(alpha: 0.6),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: onProfilePressed,
            tooltip: 'Profile',
            icon: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF6366F1).withValues(alpha: 0.5),
                ),
              ),
              child: const Icon(Icons.person_outline_rounded, size: 22),
            ),
          ),
        ],
      ),
    );
  }
}
