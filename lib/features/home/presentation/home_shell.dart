import 'dart:async';

import 'package:flutter/material.dart';

import '../../chat/data/chat_repository.dart';
import '../../chat/presentation/chat_screen.dart';
import '../../chat/presentation/meeting_recorder_screen.dart';
import '../../dashboard/data/agent_nudge_service.dart';
import '../../dashboard/data/passive_nudge_coordinator.dart';
import '../../dashboard/models/agent_insights.dart';
import '../../dashboard/presentation/dashboard_screen.dart';
import '../../dashboard/presentation/reports_screen.dart';
import '../../whatsapp/data/whatsapp_inbox_repository.dart';
import '../../whatsapp/presentation/whatsapp_conversations_screen.dart';
import 'aivy_voice_home_screen.dart';
import 'more_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.userId});

  final String userId;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final ChatRepository _repository;
  late final AgentNudgeService _nudgeService;
  late final PassiveNudgeCoordinator _passiveNudges;
  late final WhatsAppInboxRepository _whatsAppInboxRepository;
  StreamSubscription<int>? _unreadWhatsAppSub;
  int _unreadWhatsAppCount = 0;
  int _currentIndex = 0;
  int _reportsResyncTick = 0;
  AgentInsights? _launchInsights;
  String? _activeChatId;
  StreamSubscription<String?>? _activeChatSub;

  @override
  void initState() {
    super.initState();
    _repository = ChatRepository();
    _nudgeService = AgentNudgeService(repository: _repository);
    _passiveNudges = PassiveNudgeCoordinator(repository: _repository);
    _whatsAppInboxRepository = WhatsAppInboxRepository();
    unawaited(_bootstrapChatSession());
    _activeChatSub = _repository.watchActiveChatId(widget.userId).listen(
      (id) {
        if (!mounted || id == null || id.isEmpty) {
          return;
        }
        if (id != _activeChatId) {
          setState(() => _activeChatId = id);
        }
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runLaunchPipeline();
    });
    _unreadWhatsAppSub = _whatsAppInboxRepository.watchUnreadBadgeCount().listen((
      count,
    ) {
      if (!mounted || count == _unreadWhatsAppCount) {
        return;
      }
      setState(() => _unreadWhatsAppCount = count);
    });
  }

  Future<void> _bootstrapChatSession() async {
    try {
      final id = await _repository.ensureActiveChatSession(widget.userId);
      if (!mounted) {
        return;
      }
      setState(() => _activeChatId = id);
    } catch (e, st) {
      debugPrint('HomeShell: chat session bootstrap failed: $e\n$st');
    }
  }

  Future<void> _onNewChat() async {
    final id = await _repository.createChat(widget.userId);
    if (!mounted) {
      return;
    }
    setState(() => _activeChatId = id);
  }

  Future<void> _onSelectChat(String chatId) async {
    await _repository.setActiveChatId(widget.userId, chatId);
    if (!mounted) {
      return;
    }
    setState(() => _activeChatId = chatId);
  }

  Future<void> _onDeleteChat(String chatId) async {
    await _repository.deleteChat(widget.userId, chatId);
  }

  @override
  void dispose() {
    unawaited(_activeChatSub?.cancel());
    unawaited(_unreadWhatsAppSub?.cancel());
    super.dispose();
  }

  /// Sequences the launch-time "proactive agent" work:
  ///   1. Compute insights.
  ///   2. Fire a throttled passive nudge notification if warranted.
  Future<void> _runLaunchPipeline() async {
    await _loadLaunchInsights();
    final insights = _launchInsights;
    if (insights != null) {
      await _passiveNudges.maybeNudge(
        userId: widget.userId,
        insights: insights,
      );
    }
  }

  Future<void> _loadLaunchInsights() async {
    try {
      final insights = await _nudgeService.generateLaunchInsights(
        widget.userId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _launchInsights = insights;
      });
    } catch (error, stackTrace) {
      debugPrint(
        'HomeShell: failed to generate launch insights: $error\n$stackTrace',
      );
    }
  }

  void _openChatTab() {
    setState(() {
      _currentIndex = 1;
    });
  }

  void _openMeetings() {
    final chatId = _activeChatId;
    if (chatId == null) {
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => MeetingRecorderScreen(
          userId: widget.userId,
          activeChatId: chatId,
        ),
      ),
    );
  }

  PreferredSizeWidget? _buildAppBar(BuildContext context) {
    final theme = Theme.of(context);
    switch (_currentIndex) {
      case 0:
      case 1:
      case 3:
        return null;
      case 2:
        return AppBar(
          title: const Text('WhatsApp Inbox'),
          backgroundColor: theme.colorScheme.surface,
        );
      case 4:
        return AppBar(
          title: const Text('Reports'),
          backgroundColor: theme.colorScheme.surface,
          actions: [
            IconButton(
              tooltip: 'Refresh data',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () {
                setState(() => _reportsResyncTick++);
              },
            ),
          ],
        );
      case 5:
      default:
        return AppBar(
          title: const Text('More'),
          backgroundColor: theme.colorScheme.surface,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isVoiceHome = _currentIndex == 0;
    final isChat = _currentIndex == 1;
    final isJarvisNav = isVoiceHome || isChat;

    final screens = [
      AivyVoiceHomeScreen(userId: widget.userId),
      ChatScreen(
        userId: widget.userId,
        activeChatId: _activeChatId,
        onNewChat: _onNewChat,
        onSelectChat: _onSelectChat,
        onDeleteChat: _onDeleteChat,
      ),
      WhatsAppConversationsScreen(
        ownerUid: widget.userId,
        repository: _whatsAppInboxRepository,
      ),
      DashboardScreen(
        userId: widget.userId,
        activeChatId: _activeChatId,
        onOpenChat: _openChatTab,
        onOpenMeetings: _openMeetings,
      ),
      ReportsScreen(
        key: ValueKey<int>(_reportsResyncTick),
        userId: widget.userId,
        launchInsights: _launchInsights,
      ),
      MoreScreen(userId: widget.userId),
    ];

    return Scaffold(
      extendBodyBehindAppBar: isVoiceHome || _currentIndex == 3,
      backgroundColor: (isChat || isVoiceHome)
          ? const Color(0xFF030712)
          : theme.scaffoldBackgroundColor,
      appBar: _buildAppBar(context),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          for (var i = 0; i < screens.length; i++)
            TickerMode(
              enabled: i == _currentIndex,
              child: screens[i],
            ),
        ],
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: isJarvisNav
              ? const Color(0xFF0E0E14)
              : theme.colorScheme.surface,
          indicatorColor: isJarvisNav
              ? const Color(0xFF6366F1).withValues(alpha: 0.35)
              : theme.colorScheme.secondaryContainer,
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            if (!isJarvisNav) {
              return theme.textTheme.labelMedium;
            }
            if (states.contains(WidgetState.selected)) {
              return theme.textTheme.labelMedium?.copyWith(
                color: const Color(0xFFC4B5FD),
                fontWeight: FontWeight.w600,
              );
            }
            return theme.textTheme.labelMedium?.copyWith(
              color: const Color(0xFF64748B),
            );
          }),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final base = theme.iconTheme;
            if (!isJarvisNav) {
              return base.copyWith(color: theme.colorScheme.onSurfaceVariant);
            }
            if (states.contains(WidgetState.selected)) {
              return base.copyWith(color: const Color(0xFFA78BFA));
            }
            return base.copyWith(color: const Color(0xFF64748B));
          }),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          surfaceTintColor: Colors.transparent,
          onDestinationSelected: (index) {
            setState(() {
              _currentIndex = index;
            });
          },
          destinations: [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: 'Chat',
            ),
            NavigationDestination(
              icon: _unreadWhatsAppCount > 0
                  ? Badge(
                      label: Text('$_unreadWhatsAppCount'),
                      child: const Icon(Icons.mark_chat_unread_outlined),
                    )
                  : const Icon(Icons.mark_chat_read_outlined),
              selectedIcon: _unreadWhatsAppCount > 0
                  ? Badge(
                      label: Text('$_unreadWhatsAppCount'),
                      child: const Icon(Icons.mark_chat_unread_rounded),
                    )
                  : const Icon(Icons.mark_chat_read_rounded),
              label: 'WhatsApp',
            ),
            NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard_rounded),
              label: 'Dashboard',
            ),
            NavigationDestination(
              icon: Icon(Icons.bar_chart_outlined),
              selectedIcon: Icon(Icons.bar_chart_rounded),
              label: 'Reports',
            ),
            NavigationDestination(
              icon: Icon(Icons.more_horiz),
              selectedIcon: Icon(Icons.more_horiz),
              label: 'More',
            ),
          ],
        ),
      ),
    );
  }
}
