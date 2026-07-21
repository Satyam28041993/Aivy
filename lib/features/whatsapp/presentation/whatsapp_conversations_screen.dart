import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/whatsapp_inbox_repository.dart';
import '../models/whatsapp_conversation.dart';
import 'whatsapp_chat_detail_screen.dart';

class WhatsAppConversationsScreen extends StatefulWidget {
  const WhatsAppConversationsScreen({
    super.key,
    required this.ownerUid,
    required this.repository,
  });

  final String ownerUid;
  final WhatsAppInboxRepository repository;

  @override
  State<WhatsAppConversationsScreen> createState() =>
      _WhatsAppConversationsScreenState();
}

class _WhatsAppConversationsScreenState extends State<WhatsAppConversationsScreen> {
  final _searchCtrl = TextEditingController();
  String _leadFilter = 'all';
  bool _unreadOnly = false;
  String? _selectedConversationId;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<WhatsAppConversation> _applyFilters(List<WhatsAppConversation> rows) {
    final q = _searchCtrl.text.trim().toLowerCase();
    return rows.where((row) {
      if (_unreadOnly && row.unreadCountAdmin <= 0) {
        return false;
      }
      if (_leadFilter != 'all' && row.leadStatus != _leadFilter) {
        return false;
      }
      if (q.isEmpty) {
        return true;
      }
      return row.customerName.toLowerCase().contains(q) ||
          row.phone.toLowerCase().contains(q) ||
          row.lastMessage.toLowerCase().contains(q);
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final df = DateFormat('dd MMM, hh:mm a');
    return StreamBuilder<List<WhatsAppConversation>>(
      stream: widget.repository.watchConversationsForOwner(widget.ownerUid),
      builder: (context, snap) {
        final all = snap.data ?? const <WhatsAppConversation>[];
        final rows = _applyFilters(all);
        final width = MediaQuery.sizeOf(context).width;
        final isWide = width >= 900;
        final selected = rows.where((e) => e.id == _selectedConversationId).isNotEmpty
            ? rows.firstWhere((e) => e.id == _selectedConversationId)
            : (rows.isNotEmpty ? rows.first : null);
        if (isWide && selected != null && _selectedConversationId == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() => _selectedConversationId = selected.id);
            }
          });
        }

        Widget listPane() {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                child: Column(
                  children: [
                    TextField(
                      controller: _searchCtrl,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.search_rounded),
                        hintText: 'Search name, phone, message',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: _leadFilter,
                            items: const [
                              DropdownMenuItem(value: 'all', child: Text('All leads')),
                              DropdownMenuItem(value: 'new', child: Text('New')),
                              DropdownMenuItem(value: 'warm', child: Text('Warm')),
                              DropdownMenuItem(value: 'hot', child: Text('Hot')),
                              DropdownMenuItem(value: 'customer', child: Text('Customer')),
                              DropdownMenuItem(value: 'spam', child: Text('Spam')),
                            ],
                            onChanged: (v) => setState(() => _leadFilter = v ?? 'all'),
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilterChip(
                          selected: _unreadOnly,
                          label: const Text('Unread only'),
                          onSelected: (v) => setState(() => _unreadOnly = v),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: rows.isEmpty
                    ? const Center(child: Text('No conversations found'))
                    : ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final c = rows[index];
                          final selectedTile = c.id == _selectedConversationId;
                          final lastText = c.lastMessage.isNotEmpty
                              ? c.lastMessage
                              : '[${c.lastMessageType}]';
                          return ListTile(
                            selected: selectedTile,
                            leading: CircleAvatar(
                              child: Text(
                                c.customerName.isEmpty
                                    ? '?'
                                    : c.customerName.characters.first.toUpperCase(),
                              ),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    c.customerName,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (c.unreadCountAdmin > 0)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      '${c.unreadCountAdmin}',
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.onPrimary,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(c.phone, style: theme.textTheme.labelSmall),
                                Text(
                                  lastText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '${c.leadStatus.toUpperCase()}  •  ${c.lastMessageAtMs > 0 ? df.format(DateTime.fromMillisecondsSinceEpoch(c.lastMessageAtMs)) : '-'}',
                                  style: theme.textTheme.labelSmall,
                                ),
                              ],
                            ),
                            onTap: () {
                              if (isWide) {
                                setState(() => _selectedConversationId = c.id);
                                return;
                              }
                              Navigator.of(context).push<void>(
                                MaterialPageRoute<void>(
                                  builder: (context) => WhatsAppChatDetailScreen(
                                    conversation: c,
                                    repository: widget.repository,
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          );
        }

        if (!isWide) {
          return Scaffold(
            appBar: AppBar(title: const Text('WhatsApp Inbox')),
            body: listPane(),
          );
        }

        return Row(
          children: [
            SizedBox(width: 380, child: listPane()),
            const VerticalDivider(width: 1),
            Expanded(
              child: selected == null
                  ? const Center(child: Text('Select a conversation'))
                  : WhatsAppChatDetailScreen(
                      key: ValueKey<String>(selected.id),
                      conversation: selected,
                      repository: widget.repository,
                    ),
            ),
          ],
        );
      },
    );
  }
}
