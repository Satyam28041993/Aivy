import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/agent_models.dart';
import 'agent_action_card.dart';
import 'message_links.dart';

/// One turn in the conversation, with any confirm cards attached below it.
class AgentMessageBubble extends StatelessWidget {
  const AgentMessageBubble({
    super.key,
    required this.message,
    required this.onConfirmDraft,
    required this.onEditDraft,
    required this.onCancelDraft,
    this.busyDraftId,
    this.draftOverrides = const {},
  });

  final AgentMessage message;
  final ValueChanged<AgentDraft> onConfirmDraft;
  final ValueChanged<AgentDraft> onEditDraft;
  final ValueChanged<AgentDraft> onCancelDraft;

  /// Draft currently being committed, so its card can show progress.
  final String? busyDraftId;

  /// Live status per draft id — a card stored as `pending` may since have been
  /// committed, and the stored copy on the message never changes.
  final Map<String, String> draftOverrides;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (message.text.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.82,
              ),
              child: _bubble(context, isUser),
            ),
          for (final draft in message.drafts)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.90,
              ),
              child: AgentActionCard(
                draft: draft.copyWith(status: draftOverrides[draft.id]),
                busy: busyDraftId == draft.id,
                onConfirm: () => onConfirmDraft(draft),
                onEdit: () => onEditDraft(draft),
                onCancel: () => onCancelDraft(draft),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bubble(BuildContext context, bool isUser) {
    // A bare map URL in the middle of a sentence is unreadable and, worse, was
    // not tappable at all — so links are lifted out of the text and shown as
    // buttons underneath it, the way a shared location arrives on WhatsApp.
    final links = extractLinks(message.text);
    final body = stripLinks(message.text, links);

    return GestureDetector(
      onLongPress: () async {
        await Clipboard.setData(ClipboardData(text: message.text));
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Copied'),
            duration: Duration(seconds: 1),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isUser ? 18 : 5),
            bottomRight: Radius.circular(isUser ? 5 : 18),
          ),
          gradient: isUser
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF7C3AED), Color(0xFF6D28D9)],
                )
              : null,
          color: isUser ? null : const Color(0xFF161B29),
          border: isUser
              ? null
              : Border.all(color: Colors.white.withValues(alpha: 0.07)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (body.isNotEmpty)
              SelectableText(
                body,
                style: TextStyle(
                  color: isUser ? Colors.white : const Color(0xFFE7EDF5),
                  fontSize: 15,
                  height: 1.42,
                  fontWeight: FontWeight.w400,
                ),
              ),
            if (links.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: body.isEmpty ? 0 : 9),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final l in links) _LinkChip(link: l)],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.link});

  final MessageLink link;

  Future<void> _open(BuildContext context) async {
    final uri = Uri.tryParse(link.url);
    var ok = false;
    if (uri != null) {
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        // A blocked pop-up on web throws rather than returning false.
        ok = false;
      }
    }
    if (ok || !context.mounted) {
      return;
    }
    // Blocked pop-up, or no app that handles it — the address is still useful.
    await Clipboard.setData(ClipboardData(text: link.url));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open it — link copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: () => _open(context),
        onLongPress: () async {
          await Clipboard.setData(ClipboardData(text: link.url));
          if (!context.mounted) {
            return;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Link copied'),
              duration: Duration(seconds: 1),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(link.icon, size: 16, color: const Color(0xFF22D3EE)),
              const SizedBox(width: 7),
              Text(
                link.label,
                style: const TextStyle(
                  color: Color(0xFFE7EDF5),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Three dots while Aivy is working out a reply.
class AgentTypingIndicator extends StatefulWidget {
  const AgentTypingIndicator({super.key});

  @override
  State<AgentTypingIndicator> createState() => _AgentTypingIndicatorState();
}

class _AgentTypingIndicatorState extends State<AgentTypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomRight: Radius.circular(18),
            bottomLeft: Radius.circular(5),
          ),
          color: const Color(0xFF161B29),
          border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                final phase = (_controller.value - i * 0.18) % 1.0;
                final lift = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
                return Padding(
                  padding: EdgeInsets.only(right: i == 2 ? 0 : 5),
                  child: Transform.translate(
                    offset: Offset(0, -3 * lift),
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF22D3EE)
                            .withValues(alpha: 0.45 + 0.45 * lift),
                      ),
                    ),
                  ),
                );
              }),
            );
          },
        ),
      ),
    );
  }
}
