import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/whatsapp_inbox_repository.dart';
import '../models/whatsapp_conversation.dart';
import '../models/whatsapp_message.dart';

class WhatsAppChatDetailScreen extends StatefulWidget {
  const WhatsAppChatDetailScreen({
    super.key,
    required this.conversation,
    required this.repository,
  });

  final WhatsAppConversation conversation;
  final WhatsAppInboxRepository repository;

  @override
  State<WhatsAppChatDetailScreen> createState() => _WhatsAppChatDetailScreenState();
}

class _WhatsAppChatDetailScreenState extends State<WhatsAppChatDetailScreen> {
  final _replyCtrl = TextEditingController();
  bool _sending = false;
  bool _markingRead = false;
  late String _leadStatus;

  @override
  void initState() {
    super.initState();
    _leadStatus = widget.conversation.leadStatus;
    _markAsRead();
  }

  Future<void> _markAsRead() async {
    if (_markingRead) {
      return;
    }
    _markingRead = true;
    try {
      await widget.repository.markConversationRead(widget.conversation.id);
    } catch (_) {
      // no-op: UI should remain usable even if read marker fails.
    } finally {
      _markingRead = false;
    }
  }

  @override
  void dispose() {
    _replyCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendReply() async {
    final text = _replyCtrl.text.trim();
    if (text.isEmpty || _sending) {
      return;
    }
    setState(() => _sending = true);
    try {
      await widget.repository.sendAdminReply(
        conversationId: widget.conversation.id,
        phone: widget.conversation.phone,
        message: text,
      );
      if (!mounted) {
        return;
      }
      _replyCtrl.clear();
    } catch (e) {
      if (mounted) {
        final msg = '$e'.replaceFirst('Exception: ', '').trim();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg.isEmpty ? 'Send failed' : msg)),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _openDirectWhatsApp() async {
    final phone = widget.conversation.phone.trim();
    if (phone.isEmpty) {
      return;
    }
    final uri = Uri.parse('https://wa.me/$phone');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _setLeadStatus(String? value) async {
    final v = (value ?? '').trim();
    if (v.isEmpty || v == _leadStatus) {
      return;
    }
    setState(() => _leadStatus = v);
    await widget.repository.setLeadStatus(
      conversationId: widget.conversation.id,
      leadStatus: v,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final df = DateFormat('dd MMM, hh:mm a');
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.conversation.customerName),
            Text(
              widget.conversation.phone,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Send WhatsApp',
            onPressed: _openDirectWhatsApp,
            icon: const Icon(Icons.open_in_new_rounded),
          ),
          Builder(
            builder: (ctx) => IconButton(
              tooltip: 'Customer profile',
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
              icon: const Icon(Icons.person_outline),
            ),
          ),
        ],
      ),
      endDrawer: Drawer(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Customer profile', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Name'),
              subtitle: Text(widget.conversation.customerName),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Phone'),
              subtitle: SelectableText(widget.conversation.phone),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Lead status'),
              subtitle: DropdownButtonFormField<String>(
                value: _leadStatus,
                items: const [
                  DropdownMenuItem(value: 'new', child: Text('New')),
                  DropdownMenuItem(value: 'warm', child: Text('Warm')),
                  DropdownMenuItem(value: 'hot', child: Text('Hot')),
                  DropdownMenuItem(value: 'customer', child: Text('Customer')),
                  DropdownMenuItem(value: 'spam', child: Text('Spam')),
                ],
                onChanged: _setLeadStatus,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _openDirectWhatsApp,
              icon: const Icon(Icons.send_rounded),
              label: const Text('Send WhatsApp'),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<WhatsAppMessage>>(
              stream: widget.repository.watchMessages(widget.conversation.id),
              builder: (context, snap) {
                final messages = snap.data ?? const <WhatsAppMessage>[];
                if (snap.connectionState == ConnectionState.waiting && messages.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (messages.isEmpty) {
                  return const Center(child: Text('No messages yet'));
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final m = messages[index];
                    final mine = m.isOutbound;
                    final bubbleColor = mine
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest;
                    return Align(
                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          color: bubbleColor,
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _MessageBody(message: m),
                                const SizedBox(height: 8),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (m.aiPending)
                                      Container(
                                        margin: const EdgeInsets.only(right: 6),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(12),
                                          color: theme.colorScheme.tertiaryContainer,
                                        ),
                                        child: Text(
                                          'AI pending',
                                          style: theme.textTheme.labelSmall,
                                        ),
                                      ),
                                    Text(
                                      df.format(
                                        DateTime.fromMillisecondsSinceEpoch(
                                          m.createdAtMs <= 0
                                              ? DateTime.now().millisecondsSinceEpoch
                                              : m.createdAtMs,
                                        ),
                                      ),
                                      style: theme.textTheme.labelSmall,
                                    ),
                                    const SizedBox(width: 6),
                                    if (mine) _StatusIcon(status: m.lastStatus),
                                    if (mine && m.lastStatus.isNotEmpty) ...[
                                      const SizedBox(width: 6),
                                      Text(
                                        m.lastStatus,
                                        style: theme.textTheme.labelSmall?.copyWith(
                                          color: theme.colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _replyCtrl,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        hintText:
                            'Admin reply…  Aivy Chat: "Naam ko WhatsApp pe massege bhejo ki …"',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _sending ? null : _sendReply,
                    child: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBody extends StatelessWidget {
  const _MessageBody({required this.message});

  final WhatsAppMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (message.type == 'text') {
      return Text(message.textBody.isEmpty ? '—' : message.textBody);
    }
    final media = message.media ?? const <String, dynamic>{};
    final mime = (media['mimeType'] ?? '').toString();
    final file = (media['filename'] ?? '').toString();
    if (message.type == 'image') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 120,
            width: 180,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: theme.colorScheme.surface,
            ),
            child: const Icon(Icons.image_outlined, size: 42),
          ),
          if (message.textBody.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(message.textBody),
          ],
          if (mime.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(mime, style: theme.textTheme.labelSmall),
          ],
        ],
      );
    }
    if (message.type == 'document') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.description_outlined),
          const SizedBox(width: 8),
          Flexible(
            child: Text(file.isNotEmpty ? file : 'Document attachment'),
          ),
        ],
      );
    }
    if (message.type == 'audio') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.mic_none_rounded),
          const SizedBox(width: 8),
          Flexible(
            child: Text(mime.isNotEmpty ? mime : 'Audio message'),
          ),
        ],
      );
    }
    return Text('Unsupported message type: ${message.type}');
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    if (status == 'read') {
      return const Icon(Icons.done_all_rounded, size: 16, color: Colors.blue);
    }
    if (status == 'delivered') {
      return const Icon(Icons.done_all_rounded, size: 16);
    }
    if (status == 'sent') {
      return const Icon(Icons.done_rounded, size: 16);
    }
    return const SizedBox.shrink();
  }
}
