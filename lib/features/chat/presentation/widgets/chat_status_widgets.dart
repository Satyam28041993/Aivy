import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

class MessageAppear extends StatelessWidget {
  const MessageAppear({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      builder: (context, t, c) {
        final v = t.clamp(0.0, 1.0);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, (1 - v) * 10),
            child: c,
          ),
        );
      },
      child: child,
    );
  }
}

class TypingIndicatorGlow extends StatefulWidget {
  const TypingIndicatorGlow({super.key});

  @override
  State<TypingIndicatorGlow> createState() => _TypingIndicatorGlowState();
}

class _TypingIndicatorGlowState extends State<TypingIndicatorGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) {
            final t = _pulse.value;
            final breathe = 0.5 + 0.5 * math.sin(t * math.pi * 2);
            return Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF6366F1)
                        .withValues(alpha: 0.18 + 0.28 * breathe),
                    blurRadius: 16 + 12 * breathe,
                    spreadRadius: -2,
                  ),
                  BoxShadow(
                    color: const Color(0xFF22D3EE)
                        .withValues(alpha: 0.12 + 0.2 * breathe),
                    blurRadius: 22 + 8 * breathe,
                  ),
                ],
              ),
              child: child,
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF0C0D14).withValues(alpha: 0.78),
                      const Color(0xFF121826).withValues(alpha: 0.62),
                    ],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _GlowingDot(phase: _pulse.value * 2 * math.pi),
                    const SizedBox(width: 6),
                    _GlowingDot(phase: _pulse.value * 2 * math.pi + 0.8),
                    const SizedBox(width: 6),
                    _GlowingDot(phase: _pulse.value * 2 * math.pi + 1.6),
                    const SizedBox(width: 10),
                    Text(
                      'Aivy is thinking',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: const Color(0xFF94A3B8),
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

class _GlowingDot extends StatelessWidget {
  const _GlowingDot({required this.phase});

  final double phase;

  @override
  Widget build(BuildContext context) {
    final o = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(phase));
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFA78BFA).withValues(alpha: o),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF22D3EE).withValues(alpha: 0.35 * o),
            blurRadius: 6,
          ),
        ],
      ),
    );
  }
}

class ChatIntroView extends StatelessWidget {
  const ChatIntroView({super.key, required this.topPadding});

  final double topPadding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: EdgeInsets.fromLTRB(24, topPadding, 24, 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFFA78BFA).withValues(alpha: 0.65),
                          const Color(0xFF22D3EE).withValues(alpha: 0.45),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF8B5CF6).withValues(alpha: 0.45),
                          blurRadius: 28,
                        ),
                      ],
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(18),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF121826),
                      ),
                      child: ShaderMask(
                        blendMode: BlendMode.srcIn,
                        shaderCallback: (bounds) => const LinearGradient(
                          colors: [
                            Color(0xFFE9D5FF),
                            Color(0xFFA78BFA),
                            Color(0xFF38BDF8),
                          ],
                        ).createShader(bounds),
                        child: const Icon(
                          Icons.auto_awesome_rounded,
                          size: 40,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Send a message to log notes, reminders, or quotations.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: const Color(0xFF94A3B8),
                          height: 1.45,
                        ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
