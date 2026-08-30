import 'package:flutter/material.dart';

import '../../models/agent_models.dart';

/// The confirm card for a proposed write.
///
/// This is the safety rail for the whole screen: a tool never writes, it
/// proposes, and the proposal is spelled out here — full date in words, client
/// name, amount — so a misunderstanding is caught before it reaches the ledger
/// rather than discovered in a report weeks later.
///
/// "Badlo" deliberately has no field picker. It puts the cursor back in the
/// composer, because correcting by speaking ("12 baje kar do") is the whole
/// point of the screen.
class AgentActionCard extends StatelessWidget {
  const AgentActionCard({
    super.key,
    required this.draft,
    required this.onConfirm,
    required this.onEdit,
    required this.onCancel,
    this.busy = false,
  });

  final AgentDraft draft;
  final VoidCallback onConfirm;
  final VoidCallback onEdit;
  final VoidCallback onCancel;
  final bool busy;

  static const _accent = Color(0xFF22D3EE);
  static const _done = Color(0xFF34D399);
  static const _muted = Color(0xFF94A3B8);

  @override
  Widget build(BuildContext context) {
    final settled = !draft.isPending;
    final borderColor = draft.isCommitted
        ? _done.withValues(alpha: 0.45)
        : settled
            ? const Color(0xFF334155)
            : _accent.withValues(alpha: 0.40);

    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF0F172A).withValues(alpha: 0.92),
            const Color(0xFF131A2C).withValues(alpha: 0.86),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(context, settled),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final line in draft.lines) _line(context, line),
              ],
            ),
          ),
          if (draft.isPending) _actions(context) else _settledFooter(context),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, bool settled) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Row(
        children: [
          Text(draft.icon, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              draft.title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: const Color(0xFFE2E8F0),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
            ),
          ),
          if (!settled)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: _accent.withValues(alpha: 0.12),
                border: Border.all(color: _accent.withValues(alpha: 0.3)),
              ),
              child: const Text(
                'not saved',
                style: TextStyle(
                  color: _accent,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, AgentCardLine line) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              line.label,
              style: const TextStyle(
                color: _muted,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              line.value,
              style: const TextStyle(
                color: Color(0xFFF1F5F9),
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: _button(
              label: busy ? 'Saving…' : 'Looks right',
              icon: Icons.check_rounded,
              filled: true,
              onTap: busy ? null : onConfirm,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _button(
              label: 'Badlo',
              icon: Icons.edit_outlined,
              filled: false,
              onTap: busy ? null : onEdit,
            ),
          ),
          const SizedBox(width: 8),
          _iconButton(
            icon: Icons.close_rounded,
            onTap: busy ? null : onCancel,
            tooltip: 'Rehne do',
          ),
        ],
      ),
    );
  }

  Widget _settledFooter(BuildContext context) {
    final committed = draft.isCommitted;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: Row(
        children: [
          Icon(
            committed ? Icons.check_circle_rounded : Icons.cancel_outlined,
            size: 16,
            color: committed ? _done : _muted,
          ),
          const SizedBox(width: 6),
          Text(
            committed ? 'Saved' : 'Cancelled',
            style: TextStyle(
              color: committed ? _done : _muted,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _button({
    required String label,
    required IconData icon,
    required bool filled,
    required VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return Material(
      color: filled
          ? _accent.withValues(alpha: enabled ? 0.16 : 0.06)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: filled
                  ? _accent.withValues(alpha: enabled ? 0.5 : 0.2)
                  : const Color(0xFF334155),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: filled
                    ? (enabled ? _accent : _muted)
                    : const Color(0xFFCBD5E1),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: filled
                        ? (enabled ? _accent : _muted)
                        : const Color(0xFFCBD5E1),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required VoidCallback? onTap,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(11),
          child: Container(
            width: 40,
            height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: Icon(icon, size: 17, color: _muted),
          ),
        ),
      ),
    );
  }
}
