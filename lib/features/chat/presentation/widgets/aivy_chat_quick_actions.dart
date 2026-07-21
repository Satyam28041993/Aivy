import 'package:flutter/material.dart';

import '../../utils/smart_command_expand.dart';

/// Overrides the default analytics strip (e.g. in-chat Confirm / Edit / Cancel).
class FlowQuickChip {
  const FlowQuickChip({
    required this.label,
    required this.sendText,
  });

  /// Text shown on the pill.
  final String label;
  /// Sends as user message ([onSend]); must match handlers in [ControlledChatFlow].
  final String sendText;
}

/// Compact shortcuts above the chat field — each sends the same text as
/// [expandSmartCommandInput] would route for `/n`.
class AivyChatQuickActions extends StatelessWidget {
  const AivyChatQuickActions({
    super.key,
    required this.enabled,
    required this.onSend,
    /// When non-null/non-empty, replaces [kAivyQuickActionBar] below the composer.
    this.flowChipOverride,
  });

  final bool enabled;
  final ValueChanged<String> onSend;

  /// Set from [watchChatFlowState] when awaiting confirm / edit picker, etc.
  final List<FlowQuickChip>? flowChipOverride;

  @override
  Widget build(BuildContext context) {
    final overrides = flowChipOverride;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            if (overrides != null && overrides.isNotEmpty)
              ..._flowOverrideRows(overrides)
            else
              ..._defaultBarRows(),
          ],
        ),
      ),
    );
  }

  List<Widget> _flowOverrideRows(List<FlowQuickChip> overrides) {
    final out = <Widget>[];
    for (final a in overrides) {
      out.add(
        _QuickChip(
          label: a.label,
          enabled: enabled,
          onPressed: () => onSend(a.sendText),
        ),
      );
      out.add(const SizedBox(width: 8));
    }
    if (out.isNotEmpty) {
      out.removeLast();
    }
    return out;
  }

  List<Widget> _defaultBarRows() {
    final out = <Widget>[];
    for (final a in kAivyQuickActionBar) {
      out.add(
        _QuickChip(
          label: '[${a.n}] ${a.label}',
          enabled: enabled,
          onPressed: () => onSend(a.sendText),
        ),
      );
      out.add(const SizedBox(width: 8));
    }
    if (out.isNotEmpty) {
      out.removeLast();
    }
    return out;
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1A1D27),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: const Color(0xFF2D3A4F).withValues(alpha: enabled ? 0.9 : 0.4),
            ),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: enabled
                      ? const Color(0xFFE2E8F0)
                      : const Color(0xFF64748B),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
          ),
        ),
      ),
    );
  }
}
