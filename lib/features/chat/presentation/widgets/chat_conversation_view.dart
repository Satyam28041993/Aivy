import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../core/voice/aivy_chat_voice_coordinator.dart';
import '../../../../core/voice/voice_feature_settings.dart';
import '../../data/chat_repository.dart';
import '../../models/chat_message.dart';
import 'chat_bubble.dart';
import 'chat_status_widgets.dart';

/// Renders the scrollable message list with stream subscription (avoids
/// setState during [StreamBuilder.build]), auto-scroll, and error surface.
class ChatConversationView extends StatefulWidget {
  const ChatConversationView({
    super.key,
    required this.userId,
    required this.chatId,
    required this.repository,
    required this.scrollController,
    required this.topPadding,
    required this.isAwaitingAssistant,
    this.onQuickSend,
    this.autoPlayAssistantTts = true,
  });

  final String userId;
  final String chatId;
  final ChatRepository repository;
  final ScrollController scrollController;
  final double topPadding;
  final bool isAwaitingAssistant;
  /// Sends a user message without using the input field (e.g. order index tap).
  final Future<void> Function(String text)? onQuickSend;

  /// When true, new assistant messages with [ChatMessage.aivyData] `ttsAudioUrl` autoplay once.
  final bool autoPlayAssistantTts;

  @override
  State<ChatConversationView> createState() => _ChatConversationViewState();
}

class _ChatConversationViewState extends State<ChatConversationView> {
  StreamSubscription<List<ChatMessage>>? _sub;
  List<ChatMessage> _messages = const [];
  bool _ready = false;
  Object? _streamError;
  bool _stickToEnd = true;
  String? _lastAutoplayedAssistantId;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
    _attachStream();
  }

  void _attachStream() {
    unawaited(_sub?.cancel());
    _sub = widget.repository
        .watchChatMessages(widget.userId, widget.chatId)
        .listen(
      _onMessages,
      onError: (Object e, StackTrace st) {
        if (kDebugMode) {
          debugPrint('[Aivy] watchChatMessages: $e\n$st');
        }
        if (!mounted) {
          return;
        }
        setState(() {
          _streamError = e;
          _ready = true;
        });
      },
    );
  }

  @override
  void didUpdateWidget(covariant ChatConversationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatId != widget.chatId) {
      setState(() {
        _messages = const [];
        _ready = false;
        _streamError = null;
        _lastAutoplayedAssistantId = null;
      });
      _attachStream();
    }
    if (oldWidget.isAwaitingAssistant != widget.isAwaitingAssistant &&
        widget.isAwaitingAssistant) {
      _stickToEnd = true;
      _scrollToEnd();
    }
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _onMessages(List<ChatMessage> list) {
    if (!mounted) {
      return;
    }
    final prevLen = _messages.length;
    final grew = list.length > prevLen;
    final hadMessages = _messages.isNotEmpty;
    setState(() {
      _messages = list;
      _ready = true;
      _streamError = null;
    });
    if (grew &&
        widget.autoPlayAssistantTts &&
        list.isNotEmpty &&
        list.last.role == ChatRole.assistant) {
      final last = list.last;
      final raw = last.aivyData?['ttsAudioUrl'];
      final url = raw is String ? raw.trim() : '';
      if (url.isNotEmpty && last.id != _lastAutoplayedAssistantId) {
        _lastAutoplayedAssistantId = last.id;
        unawaited(_maybeAutoplayAssistantTts(url));
      }
    }
    if (_stickToEnd && (list.isNotEmpty || !hadMessages)) {
      _scrollToEnd();
    }
  }

  Future<void> _maybeAutoplayAssistantTts(String url) async {
    if (!await VoiceFeatureSettings.autoPlayAssistantVoice) {
      return;
    }
    try {
      await AivyChatVoiceCoordinator.instance.playUrl(url);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Aivy] assistant TTS autoplay failed: $e');
      }
    }
  }

  void _onScroll() {
    if (!widget.scrollController.hasClients) {
      return;
    }
    final pos = widget.scrollController.position;
    const threshold = 72.0;
    final atEnd = pos.pixels >= pos.maxScrollExtent - threshold;
    if (_stickToEnd != atEnd) {
      setState(() => _stickToEnd = atEnd);
    }
  }

  void _scrollToEnd() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final c = widget.scrollController;
      if (!c.hasClients) {
        return;
      }
      c.animateTo(
        c.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_streamError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_rounded,
                size: 40,
                color: Color(0xFF94A3B8),
              ),
              const SizedBox(height: 12),
              const Text(
                "Couldn't load your conversation. Check your connection and try again.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFFE2E8F0),
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!_ready) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFA78BFA)),
      );
    }

    if (_messages.isEmpty && !widget.isAwaitingAssistant) {
      return ChatIntroView(topPadding: widget.topPadding);
    }

    final extra = widget.isAwaitingAssistant ? 1 : 0;

    return ListView.builder(
      controller: widget.scrollController,
      padding: EdgeInsets.fromLTRB(12, widget.topPadding, 12, 20),
      itemCount: _messages.length + extra,
      itemBuilder: (context, index) {
        if (extra == 1 && index == _messages.length) {
          return const TypingIndicatorGlow();
        }
        final m = _messages[index];
        return MessageAppear(
          key: ValueKey<String>(m.id),
          child: ChatBubble(
            message: m,
            onOrderDispatchQuickPick: m.role == ChatRole.assistant
                ? (String t) {
                    unawaited(widget.onQuickSend?.call(t) ?? Future.value());
                  }
                : null,
          ),
        );
      },
    );
  }
}
