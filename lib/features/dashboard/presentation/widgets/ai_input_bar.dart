import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class AiInputBar extends StatefulWidget {
  const AiInputBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    this.onMic,
    this.onMicDown,
    this.onMicUp,
    this.onHandsFreeTap,
    this.handsFreeListening = false,
    this.hintText = 'What would you like me to do?',
    this.enabled = true,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;

  /// Single tap (e.g. navigate to voice/chat). Ignored if [onMicDown] and [onMicUp] are set.
  final VoidCallback? onMic;

  /// Press-and-hold: start (e.g. native speech-to-text). Use with [onMicUp].
  final VoidCallback? onMicDown;

  /// Press-and-hold: release. Use with [onMicDown].
  final VoidCallback? onMicUp;

  /// Tap-to-toggle hands-free listening (Google Cloud path, auto-stop on silence).
  final VoidCallback? onHandsFreeTap;

  /// When true, the hands-free control shows an active (stop) affordance.
  final bool handsFreeListening;
  final String hintText;
  final bool enabled;

  @override
  State<AiInputBar> createState() => _AiInputBarState();
}

class _AiInputBarState extends State<AiInputBar> {
  bool _focused = false;

  /// Pointer id for press-and-hold mic (avoids GestureDetector cancel when IME opens).
  int? _micHoldPointer;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_syncFocus);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_syncFocus);
    super.dispose();
  }

  void _syncFocus() {
    final next = widget.focusNode.hasFocus;
    if (next != _focused) {
      setState(() => _focused = next);
    }
  }

  void _onMicPointerDown(PointerDownEvent e) {
    if (!widget.enabled ||
        widget.onMicDown == null ||
        widget.onMicUp == null) {
      return;
    }
    if (_micHoldPointer != null) {
      return;
    }
    if (e.kind != PointerDeviceKind.touch &&
        e.kind != PointerDeviceKind.stylus &&
        e.kind != PointerDeviceKind.mouse) {
      return;
    }
    _micHoldPointer = e.pointer;
    // GestureDetector + focused TextField: IME / resize often fires onTapCancel.
    // Unfocus first so the soft keyboard does not steal the gesture.
    widget.focusNode.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onMicDown!();
  }

  void _onMicPointerEnd(PointerEvent e) {
    if (_micHoldPointer != e.pointer) {
      return;
    }
    _micHoldPointer = null;
    if (!widget.enabled || widget.onMicUp == null) {
      return;
    }
    widget.onMicUp!();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const r = 22.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(r + 1),
        gradient: LinearGradient(
          colors: [
            Color(0xFF6366F1).withValues(alpha: _focused ? 0.65 : 0.28),
            Color(0xFF22D3EE).withValues(alpha: _focused ? 0.45 : 0.2),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(
              0xFF8B5CF6,
            ).withValues(alpha: _focused ? 0.38 : 0.1),
            blurRadius: _focused ? 26 : 12,
            spreadRadius: _focused ? 1 : 0,
            offset: const Offset(0, 4),
          ),
          if (_focused)
            BoxShadow(
              color: const Color(0xFF06B6D4).withValues(alpha: 0.25),
              blurRadius: 20,
              spreadRadius: -2,
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: const EdgeInsets.only(left: 14, right: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(r),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF0C0D14).withValues(alpha: 0.72),
                  const Color(0xFF121826).withValues(alpha: 0.58),
                ],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: _focused ? 0.14 : 0.08),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    enabled: widget.enabled,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      hintText: widget.hintText,
                      hintStyle: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.8,
                        ),
                        fontWeight: FontWeight.w400,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) {
                      if (widget.enabled) {
                        widget.onSend();
                      }
                    },
                  ),
                ),
                if (widget.onHandsFreeTap != null)
                  Tooltip(
                    message: widget.handsFreeListening
                        ? 'Tap to stop'
                        : 'Hands-free — tap to speak, auto-send when you pause',
                    child: IconButton(
                      onPressed: widget.onHandsFreeTap == null
                          ? null
                          : () {
                              if (widget.handsFreeListening || widget.enabled) {
                                widget.onHandsFreeTap!();
                              }
                            },
                      tooltip: 'Hands-free voice',
                      icon: Icon(
                        widget.handsFreeListening
                            ? Icons.stop_circle_rounded
                            : Icons.graphic_eq_rounded,
                        color: widget.handsFreeListening
                            ? const Color(0xFFF472B6).withValues(alpha: 0.95)
                            : const Color(0xFF22D3EE).withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                if (widget.onMicDown != null && widget.onMicUp != null)
                  Tooltip(
                    message: 'Hold to record — release to send',
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _onMicPointerDown,
                      onPointerUp: _onMicPointerEnd,
                      onPointerCancel: _onMicPointerEnd,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.mic_rounded,
                          color: widget.enabled
                              ? const Color(0xFF22D3EE).withValues(alpha: 0.95)
                              : const Color(0xFF22D3EE).withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  )
                else
                  IconButton(
                    onPressed: widget.enabled && widget.onMic != null
                        ? widget.onMic
                        : null,
                    tooltip: 'Voice',
                    icon: Icon(
                      Icons.mic_rounded,
                      color: const Color(0xFF22D3EE).withValues(alpha: 0.95),
                    ),
                  ),
                IconButton(
                  onPressed: widget.enabled ? widget.onSend : null,
                  tooltip: 'Send',
                  icon: Icon(
                    Icons.arrow_forward_rounded,
                    color: const Color(0xFFA78BFA).withValues(alpha: 0.95),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
