import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/design/aivy_ui.dart';
import '../../chat/data/chat_repository.dart';
import '../../dashboard/data/agent_nudge_service.dart';
import '../../dashboard/data/passive_nudge_coordinator.dart';
import '../../dashboard/models/agent_insights.dart';
import '../../dashboard/presentation/dashboard_screen.dart';
import '../../dashboard/presentation/reports_screen.dart';
import '../../agent/presentation/aivy_agent_screen.dart';
import 'more_screen.dart';

/// The four tabs the app is now: Aivy, Dashboard, Reports, More.
///
/// The voice home, the old command-driven Chat screen and the WhatsApp inbox
/// were removed once the agent screen replaced what they did — one place to
/// speak plainly instead of three places with different rules.
///
/// `ChatRepository` survives that removal: it is the data layer the dashboard
/// and reports read from, not the old screen's own code.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.userId});

  final String userId;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  // Tab order: Aivy, Aaj (dashboard), Records (reports), More.
  static const int _tabAgent = 0;
  static const int _tabReports = 2;

  late final ChatRepository _repository;
  late final AgentNudgeService _nudgeService;
  late final PassiveNudgeCoordinator _passiveNudges;
  int _currentIndex = _tabAgent;
  AgentInsights? _launchInsights;
  String? _activeChatId;
  StreamSubscription<String?>? _activeChatSub;

  @override
  void initState() {
    super.initState();
    _repository = ChatRepository();
    _nudgeService = AgentNudgeService(repository: _repository);
    _passiveNudges = PassiveNudgeCoordinator(repository: _repository);
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

  @override
  void dispose() {
    unawaited(_activeChatSub?.cancel());
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

  /// The dashboard's "talk to Aivy" affordance now lands on the agent.
  void _openAgentTab() {
    setState(() {
      _currentIndex = _tabAgent;
    });
  }

  /// Dashboard shows today; every "see everything" on it opens Reports.
  void _openReportsTab() {
    setState(() {
      _currentIndex = _tabReports;
    });
  }

  PreferredSizeWidget? _buildAppBar(BuildContext context) {
    // Every screen draws its own header now — each one wants a different thing
    // there (a greeting, a search field, an account row), and a shared bar
    // could only be the least useful of the three.
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      AivyAgentScreen(userId: widget.userId),
      DashboardScreen(
        userId: widget.userId,
        activeChatId: _activeChatId,
        onOpenChat: _openAgentTab,
        onOpenReports: _openReportsTab,
      ),
      ReportsScreen(
        userId: widget.userId,
        onOpenChat: _openAgentTab,
      ),
      MoreScreen(userId: widget.userId),
    ];

    return Scaffold(
      backgroundColor: AivyUi.bg,
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
          backgroundColor: AivyUi.surface,
          indicatorColor: AivyUi.brand.withValues(alpha: 0.20),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final base = Theme.of(context).textTheme.labelMedium;
            if (states.contains(WidgetState.selected)) {
              return base?.copyWith(
                color: AivyUi.brand,
                fontWeight: FontWeight.w600,
              );
            }
            return base?.copyWith(color: AivyUi.inkFaint);
          }),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final base = Theme.of(context).iconTheme;
            return base.copyWith(
              color: states.contains(WidgetState.selected)
                  ? AivyUi.brand
                  : AivyUi.inkFaint,
            );
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
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.auto_awesome_outlined),
              selectedIcon: Icon(Icons.auto_awesome),
              label: 'Aivy',
            ),
            NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard_rounded),
              label: 'Aaj',
            ),
            NavigationDestination(
              icon: Icon(Icons.bar_chart_outlined),
              selectedIcon: Icon(Icons.bar_chart_rounded),
              label: 'Records',
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
