import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/material.dart';

import '../../data/chat_repository.dart';
import '../../models/chat_session.dart';

/// ChatGPT-style session list: scrollable threads, highlight active, new chat.
class ChatSessionsSidebar extends StatefulWidget {
  const ChatSessionsSidebar({
    super.key,
    required this.userId,
    required this.repository,
    required this.activeChatId,
    required this.onNewChat,
    required this.onSelectChat,
    required this.onDeleteChat,
    this.compact = false,
  });

  final String userId;
  final ChatRepository repository;
  final String? activeChatId;
  final Future<void> Function() onNewChat;
  final Future<void> Function(String chatId) onSelectChat;
  final Future<void> Function(String chatId) onDeleteChat;
  final bool compact;

  @override
  State<ChatSessionsSidebar> createState() => _ChatSessionsSidebarState();
}

class _ChatSessionsSidebarState extends State<ChatSessionsSidebar> {
  StreamSubscription<List<ChatSession>>? _sub;
  List<ChatSession> _sessions = const [];
  Object? _error;

  @override
  void initState() {
    super.initState();
    _sub = widget.repository.watchChats(widget.userId).listen(
      (list) {
        if (!mounted) {
          return;
        }
        setState(() {
          _sessions = list;
          _error = null;
        });
      },
      onError: (Object e, StackTrace st) {
        if (kDebugMode) {
          debugPrint('[Aivy] watchChats: $e\n$st');
        }
        if (!mounted) {
          return;
        }
        setState(() => _error = e);
      },
    );
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = const Color(0xFF0F1117);
    final border = const Color(0xFF1E293B);
    final pad = widget.compact
        ? const EdgeInsets.fromLTRB(10, 12, 10, 12)
        : const EdgeInsets.fromLTRB(12, 16, 12, 16);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          right: BorderSide(color: border, width: 1),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: pad,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    'Chats',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: const Color(0xFFE2E8F0),
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                  ),
                  const Spacer(),
                  Material(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        unawaited(widget.onNewChat());
                      },
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add, size: 18, color: Color(0xFF94A3B8)),
                            SizedBox(width: 4),
                            Text(
                              'New Chat',
                              style: TextStyle(
                                color: Color(0xFFE2E8F0),
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(child: _buildList(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(
          'Could not load chats',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFF94A3B8),
              ),
        ),
      );
    }
    if (_sessions.isEmpty) {
      return Center(
        child: Text(
          'No chats yet.\nTap “New Chat” to start.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFF64748B),
                height: 1.4,
              ),
        ),
      );
    }
    return ListView.separated(
      itemCount: _sessions.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, i) {
        final s = _sessions[i];
        final active = s.id == widget.activeChatId;
        return _SessionTile(
          session: s,
          selected: active,
          onTap: () {
            unawaited(widget.onSelectChat(s.id));
          },
          onDelete: () {
            unawaited(_confirmDeleteChat(context, s));
          },
        );
      },
    );
  }

  Future<void> _confirmDeleteChat(BuildContext context, ChatSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Delete chat?',
          style: TextStyle(color: Color(0xFFE2E8F0)),
        ),
        content: Text(
          '“${s.title}” will be removed permanently. This cannot be undone.',
          style: const TextStyle(color: Color(0xFF94A3B8), height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFF87171)),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) {
      return;
    }
    try {
      await widget.onDeleteChat(s.id);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete chat: $e')),
        );
      }
    }
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  final ChatSession session;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final bg = selected
        ? const Color(0xFF1E1B4B).withValues(alpha: 0.85)
        : const Color(0xFF161922);
    final border = selected
        ? const Color(0xFF6366F1).withValues(alpha: 0.65)
        : const Color(0xFF27272F);

    return Material(
      color: Colors.transparent,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.fromLTRB(4, 2, 0, 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: const Color(0xFF6366F1).withValues(alpha: 0.18),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                    child: Text(
                      session.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: selected
                                ? const Color(0xFFE0E7FF)
                                : const Color(0xFFCBD5E1),
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                            height: 1.25,
                          ),
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              color: const Color(0xFF94A3B8),
              tooltip: 'Delete chat',
              style: IconButton.styleFrom(
                padding: const EdgeInsets.all(8),
                minimumSize: const Size(36, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
