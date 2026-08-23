import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/aivy_theme.dart';
import '../data/agent_service.dart';
import '../models/agent_models.dart';
import 'widgets/agent_history_drawer.dart';
import 'widgets/agent_message_bubble.dart';

/// The agent screen: one input, no menus, no numbered commands.
///
/// Everything the user says goes to `aivyAgent`, which decides on its own
/// whether to chat, look something up, search the web, or propose a record. The
/// screen's only jobs are showing the conversation, rendering confirm cards, and
/// keeping history reachable.
class AivyAgentScreen extends StatefulWidget {
  const AivyAgentScreen({
    super.key,
    required this.userId,
    this.service,
  });

  final String userId;

  /// Injectable for tests.
  final AgentService? service;

  @override
  State<AivyAgentScreen> createState() => _AivyAgentScreenState();
}

class _AivyAgentScreenState extends State<AivyAgentScreen> {
  late final AgentService _service;
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  StreamSubscription<List<AgentMessage>>? _messageSub;
  StreamSubscription<List<AgentChatSummary>>? _chatSub;

  List<AgentMessage> _messages = const [];
  List<AgentChatSummary> _chats = const [];

  /// Live draft statuses, so a card flips to "saved" without a stream per card.
  final Map<String, String> _draftStatus = {};

  String? _chatId;
  bool _sending = false;
  String? _busyDraftId;
  String? _error;

  /// Shown immediately so the user sees their own line before the round trip.
  String? _pendingUserText;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? AgentService();
    _chatSub = _service.watchChats(widget.userId).listen((chats) {
      if (!mounted) {
        return;
      }
      setState(() {
        _chats = chats;
        // First run: drop into the most recent conversation.
        if (_chatId == null && chats.isNotEmpty) {
          _bindChat(chats.first.id);
        }
      });
    });
    // Both drive the composer's appearance: the send button enables on text,
    // and the border lifts on focus.
    _input.addListener(_repaintComposer);
    _inputFocus.addListener(_repaintComposer);
  }

  void _repaintComposer() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    unawaited(_messageSub?.cancel());
    unawaited(_chatSub?.cancel());
    _input.removeListener(_repaintComposer);
    _inputFocus.removeListener(_repaintComposer);
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Conversation binding
  // -------------------------------------------------------------------------

  void _bindChat(String chatId) {
    if (_chatId == chatId && _messageSub != null) {
      return;
    }
    _chatId = chatId;
    unawaited(_messageSub?.cancel());
    _messageSub = _service.watchMessages(widget.userId, chatId).listen((msgs) {
      if (!mounted) {
        return;
      }
      setState(() {
        _messages = msgs;
        // The real row has arrived; drop the optimistic copy.
        if (_pendingUserText != null &&
            msgs.any((m) => m.isUser && m.text == _pendingUserText)) {
          _pendingUserText = null;
        }
      });
      _scrollToEnd();
    });
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) {
        return;
      }
      _scroll.animateTo(
        _scroll.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  // -------------------------------------------------------------------------
  // Sending
  // -------------------------------------------------------------------------

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) {
      return;
    }
    _input.clear();
    setState(() {
      _sending = true;
      _error = null;
      _pendingUserText = text;
    });
    _scrollToEnd();

    try {
      final res = await _service.send(text: text, chatId: _chatId);
      if (!mounted) {
        return;
      }
      if (res.chatId.isNotEmpty && res.chatId != _chatId) {
        _bindChat(res.chatId);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Bhej nahi paayi — dobara try kijiye.';
        // Put the text back so nothing is lost.
        _input.text = text;
        _pendingUserText = null;
      });
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _confirmDraft(AgentDraft draft) async {
    if (_busyDraftId != null) {
      return;
    }
    setState(() => _busyDraftId = draft.id);
    try {
      final res = await _service.commit(draftId: draft.id, chatId: _chatId);
      if (!mounted) {
        return;
      }
      setState(() {
        _draftStatus[draft.id] = res.ok ? 'committed' : 'pending';
      });
      if (!res.ok && res.message.isNotEmpty) {
        _snack(res.message);
      }
    } catch (_) {
      if (mounted) {
        _snack('Save nahi ho paaya — dobara try kijiye.');
      }
    } finally {
      if (mounted) {
        setState(() => _busyDraftId = null);
      }
    }
  }

  /// "Badlo" hands the correction back to speech rather than a field picker —
  /// correcting by saying "12 baje kar do" is the point of the screen.
  void _editDraft(AgentDraft draft) {
    _inputFocus.requestFocus();
    _snack('${draft.title} me kya badalna hai? Jaise "12 baje kar do"');
  }

  void _cancelDraft(AgentDraft draft) {
    setState(() => _draftStatus[draft.id] = 'cancelled');
    unawaited(_dismissDraft(draft.id));
  }

  Future<void> _dismissDraft(String draftId) async {
    try {
      await _service.cancelDraft(draftId: draftId);
    } catch (_) {
      // The card already reads cancelled; a failed dismissal is not worth a
      // banner, and the draft simply stays pending server-side.
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  // -------------------------------------------------------------------------
  // History actions
  // -------------------------------------------------------------------------

  Future<void> _newChat() async {
    Navigator.of(context).maybePop();
    try {
      final id = await _service.newChat();
      if (!mounted || id == null) {
        return;
      }
      setState(() {
        _messages = const [];
        _pendingUserText = null;
      });
      _bindChat(id);
    } catch (_) {
      if (mounted) {
        _snack('Nayi baat shuru nahi ho paayi.');
      }
    }
  }

  Future<void> _renameChat(AgentChatSummary chat) async {
    Navigator.of(context).maybePop();
    final controller = TextEditingController(text: chat.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF161B29),
        title: const Text(
          'Naam badlo',
          style: TextStyle(color: Color(0xFFE2E8F0)),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Color(0xFFE2E8F0)),
          decoration: const InputDecoration(hintText: 'Naya naam'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Rehne do'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = title?.trim() ?? '';
    if (trimmed.isEmpty) {
      return;
    }
    try {
      await _service.renameChat(chat.id, trimmed);
    } catch (_) {
      if (mounted) {
        _snack('Naam badal nahi paaya.');
      }
    }
  }

  Future<void> _deleteChat(AgentChatSummary chat) async {
    Navigator.of(context).maybePop();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF161B29),
        title: const Text(
          'Ye baat delete karein?',
          style: TextStyle(color: Color(0xFFE2E8F0)),
        ),
        content: Text(
          '"${chat.title}" hamesha ke liye hat jaayegi.',
          style: const TextStyle(color: Color(0xFF94A3B8)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Rehne do'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Color(0xFFF87171)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await _service.deleteChat(chat.id);
      if (!mounted) {
        return;
      }
      if (_chatId == chat.id) {
        setState(() {
          _messages = const [];
          _chatId = null;
        });
        unawaited(_messageSub?.cancel());
        _messageSub = null;
      }
    } catch (_) {
      if (mounted) {
        _snack('Delete nahi ho paaya.');
      }
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  bool get _hasText => _input.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AivyTheme.darkDashboard(),
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: const Color(0xFF080B12),
        drawer: AgentHistoryDrawer(
          chats: _chats,
          activeChatId: _chatId,
          onSelect: (id) {
            Navigator.of(context).maybePop();
            setState(() {
              _messages = const [];
              _pendingUserText = null;
            });
            _bindChat(id);
          },
          onNewChat: _newChat,
          onRename: _renameChat,
          onDelete: _deleteChat,
        ),
        body: SafeArea(
          child: Column(
            children: [
              _appBar(context),
              if (_error != null) _errorStrip(),
              Expanded(child: _conversation()),
              _composer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _appBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.menu_rounded, color: Color(0xFF94A3B8)),
            tooltip: 'Purani baatein',
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Aivy',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: const Color(0xFFF1F5F9),
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                ),
                const Text(
                  'jo bhi kehna ho, seedha kahiye',
                  style: TextStyle(color: Color(0xFF64748B), fontSize: 11.5),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_comment_outlined,
                color: Color(0xFF94A3B8), size: 21),
            tooltip: 'Nayi baat',
            onPressed: _newChat,
          ),
        ],
      ),
    );
  }

  Widget _errorStrip() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: const Color(0xFF7F1D1D).withValues(alpha: 0.25),
        border: Border.all(color: const Color(0xFFF87171).withValues(alpha: 0.4)),
      ),
      child: Text(
        _error!,
        style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12.5),
      ),
    );
  }

  Widget _conversation() {
    final showEmpty = _messages.isEmpty && _pendingUserText == null && !_sending;
    if (showEmpty) {
      return _emptyState();
    }
    final itemCount =
        _messages.length + (_pendingUserText != null ? 1 : 0) + (_sending ? 1 : 0);

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index < _messages.length) {
          final msg = _messages[index];
          return AgentMessageBubble(
            message: msg,
            busyDraftId: _busyDraftId,
            draftOverrides: _draftStatus,
            onConfirmDraft: _confirmDraft,
            onEditDraft: _editDraft,
            onCancelDraft: _cancelDraft,
          );
        }
        final afterMessages = index - _messages.length;
        if (_pendingUserText != null && afterMessages == 0) {
          return AgentMessageBubble(
            message: AgentMessage(
              id: '_pending',
              role: AgentRole.user,
              text: _pendingUserText!,
              createdAtMs: DateTime.now().millisecondsSinceEpoch,
            ),
            onConfirmDraft: (_) {},
            onEditDraft: (_) {},
            onCancelDraft: (_) {},
          );
        }
        return const AgentTypingIndicator();
      },
    );
  }

  Widget _emptyState() {
    const prompts = [
      'kal 11 baje rohan ke saath meeting hai new labels ke regarding',
      'aaj kisko call karna hai?',
      'koi important cheez hai kya?',
    ];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('✨', style: TextStyle(fontSize: 34)),
            const SizedBox(height: 14),
            Text(
              'Boliye, kya chal raha hai?',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: const Color(0xFFE2E8F0),
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Kaam bataiye, sawaal poochhiye, ya bas aise hi baat kijiye.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF64748B), height: 1.5, fontSize: 13),
            ),
            const SizedBox(height: 22),
            for (final p in prompts) _promptChip(p),
          ],
        ),
      ),
    );
  }

  Widget _promptChip(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: const Color(0xFF121826),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            _input.text = text;
            _inputFocus.requestFocus();
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E293B)),
            ),
            child: Text(
              text,
              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }

  Widget _composer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          color: const Color(0xFF10141F),
          border: Border.all(
            color: _inputFocus.hasFocus
                ? const Color(0xFF22D3EE).withValues(alpha: 0.45)
                : const Color(0xFF1E293B),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _inputFocus,
                enabled: !_sending,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(
                  color: Color(0xFFE7EDF5),
                  fontSize: 15,
                  height: 1.4,
                ),
                decoration: const InputDecoration(
                  hintText: 'Kuch bhi likhiye…',
                  hintStyle: TextStyle(color: Color(0xFF475569), fontSize: 15),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 13),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: _sendButton(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sendButton() {
    final enabled = _hasText && !_sending;
    return Material(
      color: enabled ? const Color(0xFF22D3EE) : const Color(0xFF1E293B),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled
            ? () {
                HapticFeedback.lightImpact();
                unawaited(_send());
              }
            : null,
        child: SizedBox(
          width: 40,
          height: 40,
          child: _sending
              ? const Padding(
                  padding: EdgeInsets.all(11),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Color(0xFF64748B)),
                  ),
                )
              : Icon(
                  Icons.arrow_upward_rounded,
                  size: 20,
                  color: enabled ? const Color(0xFF06202B) : const Color(0xFF475569),
                ),
        ),
      ),
    );
  }
}
