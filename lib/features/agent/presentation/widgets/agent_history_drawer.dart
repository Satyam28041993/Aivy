import 'package:flutter/material.dart';

import '../../models/agent_models.dart';

/// Conversation history — pick an old chat, rename it, delete it, start a new one.
class AgentHistoryDrawer extends StatelessWidget {
  const AgentHistoryDrawer({
    super.key,
    required this.chats,
    required this.activeChatId,
    required this.onSelect,
    required this.onNewChat,
    required this.onRename,
    required this.onDelete,
  });

  final List<AgentChatSummary> chats;
  final String? activeChatId;
  final ValueChanged<String> onSelect;
  final VoidCallback onNewChat;
  final void Function(AgentChatSummary chat) onRename;
  final void Function(AgentChatSummary chat) onDelete;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: const Color(0xFF0B0E17),
      child: SafeArea(
        child: Column(
          children: [
            _header(context),
            const Divider(height: 1, color: Color(0xFF1E293B)),
            Expanded(
              child: chats.isEmpty
                  ? _empty()
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: chats.length,
                      itemBuilder: (context, i) => _tile(context, chats[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Baat-cheet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: const Color(0xFFE2E8F0),
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          TextButton.icon(
            onPressed: onNewChat,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Nayi'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF22D3EE),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Text(
          'Abhi koi purani baat nahi.\nNeeche likh kar shuru kijiye.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF64748B), height: 1.5),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, AgentChatSummary chat) {
    final active = chat.id == activeChatId;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: active
            ? const Color(0xFF22D3EE).withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: () => onSelect(chat.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        chat.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: active
                              ? const Color(0xFF67E8F9)
                              : const Color(0xFFE2E8F0),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (chat.lastMessage.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          chat.lastMessage,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_vert_rounded,
                    size: 17,
                    color: Color(0xFF64748B),
                  ),
                  color: const Color(0xFF161B29),
                  onSelected: (value) {
                    if (value == 'rename') {
                      onRename(chat);
                    } else if (value == 'delete') {
                      onDelete(chat);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'rename',
                      child: Text(
                        'Naam badlo',
                        style: TextStyle(color: Color(0xFFE2E8F0)),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        'Delete',
                        style: TextStyle(color: Color(0xFFF87171)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
