import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/design/aivy_ui.dart';
import '../../../core/notifications/push_registration.dart';
import '../../chat/data/chat_repository.dart';
import '../../dashboard/data/agent_nudge_service.dart';
import '../../dashboard/data/passive_nudge_coordinator.dart';
import '../../reminders/data/reminder_alarm_sync.dart';
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
  // Tab order: Aivy, Today (dashboard), Records (reports), More.
  static const int _tabAgent = 0;
  static const int _tabReports = 2;

  late final ChatRepository _repository;
  late final AgentNudgeService _nudgeService;
  late final PassiveNudgeCoordinator _passiveNudges;
  late final ReminderAlarmSync _alarms;
  int _currentIndex = _tabAgent;
  AgentInsights? _launchInsights;
  String? _activeChatId;
  StreamSubscription<String?>? _activeChatSub;

  /// Text to drop into the agent's message box when something elsewhere in the
  /// app says "ask about this". The agent screen stays alive inside an
  /// IndexedStack, so it cannot be handed a constructor argument after the
  /// fact — it listens to this instead.
  final ValueNotifier<String?> _agentPrefill = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    _repository = ChatRepository();
    _nudgeService = AgentNudgeService(repository: _repository);
    _passiveNudges = PassiveNudgeCoordinator(repository: _repository);
    // Reminders Aivy created live only on the server until something on the
    // phone sets the alarm for them.
    _alarms = ReminderAlarmSync()..start(widget.userId);
    // Push is what arrives when the app is closed; the alarm above is the
    // offline backup for the same reminder.
    unawaited(PushRegistration().register(widget.userId));
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
    _agentPrefill.dispose();
    _alarms.dispose();
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
  /// Jump to Aivy with the question already written, from a tap on a news item
  /// or an alert. Not sent — the user may want to word it their own way.
  void _askAivyAbout(String topic) {
    final trimmed = topic.trim();
    if (trimmed.isEmpty) {
      return;
    }
    // Named as an alert or a story, and quoted, so the agent knows to go and
    // read the mail it came from before answering — and so a topic that
    // arrives truncated is visible as one.
    _agentPrefill.value =
        'Tell me more about this from my morning brief: "$trimmed". '
        'Read the mail it came from, then search the web, and give me the '
        'source links.';
    setState(() => _currentIndex = _tabAgent);
  }

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
      AivyAgentScreen(userId: widget.userId, prefill: _agentPrefill),
      DashboardScreen(
        userId: widget.userId,
        activeChatId: _activeChatId,
        onOpenChat: _openAgentTab,
        onOpenReports: _openReportsTab,
        onAskAbout: _askAivyAbout,
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
              label: 'Today',
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
