import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/design/aivy_ui.dart';
import '../data/morning_brief_service.dart';
import '../models/morning_brief.dart';
import 'widgets/morning_brief_card.dart';
import '../../chat/data/aivy_process_service.dart';
import '../../chat/data/chat_repository.dart';
import '../../clients/data/client_repository.dart';
import '../../payments/data/payment_repository.dart';
import '../../payments/models/client_pending_dues_summary.dart';
import '../../reminders/data/reminder_repository.dart';
import '../../reminders/models/reminder_item.dart';
import '../models/order_record.dart';
import '../models/quotation_record.dart';
import '../../../services/audio_service.dart';

/// Today, and nothing else.
///
/// This screen answers one question — "what needs me right now" — and every
/// other question belongs to Reports. That split is deliberate: the old
/// dashboard and the old reports screen both showed pending totals, today's
/// reminders and the order list, so neither was authoritative and both were
/// long.
///
/// The order is an owner's morning: money already late, then what is scheduled
/// today, then decisions waiting on them, then how the week is going. Anything
/// merely interesting waits for Reports.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.userId,
    this.activeChatId,
    this.onOpenChat,
    this.onOpenReports,
  });

  final String userId;
  final String? activeChatId;

  /// Opens the Aivy tab — every "ask about this" affordance lands there.
  final VoidCallback? onOpenChat;
  final VoidCallback? onOpenReports;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final ChatRepository _repository;
  late final AivyProcessService _aivyProcess;
  late final ClientRepository _clients;
  late final PaymentRepository _payments;
  late final ReminderRepository _reminders;

  final Set<String> _completing = <String>{};

  late final MorningBriefService _briefService;
  MorningBrief? _brief;
  bool _briefLoading = true;

  @override
  void initState() {
    super.initState();
    _repository = ChatRepository();
    _aivyProcess = AivyProcessService();
    _clients = ClientRepository();
    _payments = PaymentRepository(clients: _clients);
    _reminders = ReminderRepository();
    _briefService = MorningBriefService();
    unawaited(_loadBrief());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_aivyProcess.syncClientStats());
      unawaited(_aivyProcess.fetchDashboardStats());
      unawaited(_reminders.syncPendingReminderNotifications(widget.userId));
    });
  }

  @override
  void dispose() {
    _aivyProcess.dispose();
    super.dispose();
  }

  Future<void> _loadBrief({bool force = false}) async {
    if (mounted) {
      setState(() => _briefLoading = true);
    }
    final brief = await _briefService.fetch(force: force);
    if (!mounted) {
      return;
    }
    setState(() {
      _brief = brief;
      _briefLoading = false;
    });
  }

  Future<void> _complete(ReminderItem r) async {
    if (_completing.contains(r.id)) {
      return;
    }
    setState(() => _completing.add(r.id));
    try {
      await _repository.markReminderDone(
        userId: widget.userId,
        reminderId: r.id,
      );
    } catch (e) {
      debugPrint('Dashboard: completing ${r.id} failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update. Try again.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _completing.remove(r.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AivyUi.bg,
      child: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: AivyUi.brand,
          backgroundColor: AivyUi.surface,
          onRefresh: () async {
            // Pulling down is the one gesture that means "this is stale", so
            // it rebuilds the brief rather than handing back the cached one.
            await Future.wait([
              _aivyProcess.syncClientStats(),
              _loadBrief(force: true),
            ]);
            if (mounted) {
              setState(() {});
            }
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: [
              _Greeting(onAsk: widget.onOpenChat),
              const SizedBox(height: 18),
              MorningBriefCard(
                brief: _brief,
                loading: _briefLoading,
                onRetry: () => _loadBrief(force: true),
              ),
              if (_brief != null || _briefLoading) const SizedBox(height: 22),
              _MoneySection(
                payments: _payments,
                userId: widget.userId,
                onSeeAll: widget.onOpenReports,
              ),
              const SizedBox(height: 22),
              _TodaySection(
                repository: _repository,
                userId: widget.userId,
                completing: _completing,
                onComplete: _complete,
              ),
              const SizedBox(height: 22),
              _DecisionsSection(
                repository: _repository,
                userId: widget.userId,
                onSeeAll: widget.onOpenReports,
              ),
              const SizedBox(height: 22),
              _WeekSection(repository: _repository, userId: widget.userId),
              const SizedBox(height: 22),
              _AskAivy(onAsk: widget.onOpenChat),
              const SizedBox(height: 18),
              Center(
                child: TextButton.icon(
                  onPressed: () => unawaited(AudioService.playReminder()),
                  icon:
                      const Icon(Icons.notifications_active_outlined, size: 16),
                  label: const Text('Test reminder sound'),
                  style: TextButton.styleFrom(foregroundColor: AivyUi.inkFaint),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Greeting
// ---------------------------------------------------------------------------

class _Greeting extends StatelessWidget {
  const _Greeting({this.onAsk});

  final VoidCallback? onAsk;

  String get _hello {
    final h = DateTime.now().hour;
    if (h < 12) {
      return 'Good morning';
    }
    if (h < 17) {
      return 'Good afternoon';
    }
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final today = DateFormat('EEEE, d MMMM').format(DateTime.now());
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_hello, style: AivyUi.soft(context)),
              const SizedBox(height: 2),
              Text(today, style: AivyUi.title(context).copyWith(fontSize: 20)),
            ],
          ),
        ),
        if (onAsk != null)
          IconButton(
            onPressed: onAsk,
            tooltip: 'Ask Aivy',
            icon: Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: AivyUi.brandDim,
                borderRadius: BorderRadius.circular(12),
              ),
              child:
                  const Icon(Icons.auto_awesome, size: 18, color: AivyUi.brand),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Money — the number that decides the day
// ---------------------------------------------------------------------------

class _MoneySection extends StatelessWidget {
  const _MoneySection({
    required this.payments,
    required this.userId,
    this.onSeeAll,
  });

  final PaymentRepository payments;
  final String userId;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ClientPendingDuesSummary>>(
      stream: payments.watchPendingDuesGroupedByClient(userId),
      builder: (context, snap) {
        final groups = snap.data ?? const <ClientPendingDuesSummary>[];
        final now = DateTime.now().millisecondsSinceEpoch;

        var total = 0.0;
        var overdue = 0.0;
        final overdueByClient = <String, double>{};
        for (final g in groups) {
          total += g.totalPending;
          for (final d in g.dues) {
            final due = d.dueDateMs;
            final left = d.remainingAmount ?? d.amount ?? 0;
            if (due != null && due < now && left > 0) {
              overdue += left;
              overdueByClient[g.clientName] =
                  (overdueByClient[g.clientName] ?? 0) + left;
            }
          }
        }

        final worst = overdueByClient.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        final hasOverdue = overdue > 0;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AivySectionHeader(
              title: 'Money',
              action: groups.isEmpty ? null : 'See all',
              onAction: onSeeAll,
            ),
            AivyCard(
              accent: hasOverdue ? AivyUi.danger : AivyUi.ok,
              onTap: onSeeAll,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              hasOverdue ? 'Overdue' : 'To collect',
                              style: AivyUi.soft(context),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              AivyUi.inr(hasOverdue ? overdue : total),
                              style: AivyUi.display(context).copyWith(
                                color: hasOverdue ? AivyUi.danger : AivyUi.ink,
                                fontSize: 34,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (hasOverdue)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('Total pending', style: AivyUi.soft(context)),
                              const SizedBox(height: 2),
                              Text(
                                AivyUi.inr(total),
                                style: AivyUi.title(context)
                                    .copyWith(fontFeatures: AivyUi.tabular),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  if (worst.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    ...worst.take(3).map((e) {
                      final share = overdue <= 0 ? 0.0 : e.value / overdue;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    e.key,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AivyUi.body(context),
                                  ),
                                ),
                                Text(
                                  AivyUi.inrExact(e.value),
                                  style: AivyUi.body(context).copyWith(
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: AivyUi.tabular,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            AivyBar(fraction: share, color: AivyUi.danger),
                          ],
                        ),
                      );
                    }),
                    if (worst.length > 3)
                      Text(
                        '+${worst.length - 3} more clients',
                        style: AivyUi.soft(context),
                      ),
                  ] else if (!snap.hasData) ...[
                    const SizedBox(height: 12),
                    const _Loading(),
                  ] else ...[
                    const SizedBox(height: 12),
                    const AivyEmpty('Nothing overdue. All clear.'),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Today's plan
// ---------------------------------------------------------------------------

class _TodaySection extends StatelessWidget {
  const _TodaySection({
    required this.repository,
    required this.userId,
    required this.completing,
    required this.onComplete,
  });

  final ChatRepository repository;
  final String userId;
  final Set<String> completing;
  final Future<void> Function(ReminderItem) onComplete;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ReminderItem>>(
      stream: repository.watchUpcomingReminders(userId),
      builder: (context, snap) {
        final all = snap.data ?? const <ReminderItem>[];
        final now = DateTime.now();
        final endOfDay = DateTime(now.year, now.month, now.day, 23, 59, 59)
            .millisecondsSinceEpoch;

        // Anything still open from before today belongs on today's list — a
        // missed call does not stop being owed.
        final due = all
            .where((r) => r.scheduledTimeMs <= endOfDay)
            .toList(growable: false)
          ..sort((a, b) => a.scheduledTimeMs.compareTo(b.scheduledTimeMs));

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AivySectionHeader(title: 'Today', count: due.length),
            if (!snap.hasData)
              const AivyCard(child: _Loading())
            else if (due.isEmpty)
              const AivyCard(
                child: AivyEmpty('Nothing scheduled today.'),
              )
            else
              AivyCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    for (var i = 0; i < due.length && i < 6; i++) ...[
                      if (i > 0)
                        const Divider(
                          height: 1,
                          thickness: 1,
                          color: AivyUi.line,
                          indent: 16,
                          endIndent: 16,
                        ),
                      _TodayRow(
                        item: due[i],
                        busy: completing.contains(due[i].id),
                        onDone: () => onComplete(due[i]),
                      ),
                    ],
                    if (due.length > 6)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '+${due.length - 6} more',
                            style: AivyUi.soft(context),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _TodayRow extends StatelessWidget {
  const _TodayRow({
    required this.item,
    required this.busy,
    required this.onDone,
  });

  final ReminderItem item;
  final bool busy;
  final VoidCallback onDone;

  IconData get _icon {
    final t = '${item.type} ${item.subType ?? ''}'.toLowerCase();
    if (t.contains('meeting')) {
      return Icons.groups_outlined;
    }
    if (t.contains('call')) {
      return Icons.call_outlined;
    }
    if (t.contains('follow')) {
      return Icons.replay_rounded;
    }
    return Icons.task_alt_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final at = DateTime.fromMillisecondsSinceEpoch(item.scheduledTimeMs);
    final late = at.isBefore(DateTime.now());
    final title = item.title.trim().isEmpty ? item.message : item.title;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      child: Row(
        children: [
          Icon(_icon, size: 17, color: late ? AivyUi.warn : AivyUi.inkSoft),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AivyUi.body(context),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Text(
                      DateFormat('h:mm a').format(at),
                      style: AivyUi.soft(context)
                          .copyWith(fontFeatures: AivyUi.tabular),
                    ),
                    if (item.client.trim().isNotEmpty) ...[
                      Text(' · ', style: AivyUi.soft(context)),
                      Flexible(
                        child: Text(
                          item.client,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AivyUi.soft(context),
                        ),
                      ),
                    ],
                    if (late) ...[
                      const SizedBox(width: 8),
                      const AivyPill('Overdue', color: AivyUi.warn),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (busy)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            IconButton(
              onPressed: onDone,
              tooltip: 'Mark done',
              visualDensity: VisualDensity.compact,
              icon: const Icon(
                Icons.check_circle_outline,
                size: 22,
                color: AivyUi.inkFaint,
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Waiting on a decision
// ---------------------------------------------------------------------------

class _DecisionsSection extends StatelessWidget {
  const _DecisionsSection({
    required this.repository,
    required this.userId,
    this.onSeeAll,
  });

  final ChatRepository repository;
  final String userId;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<QuotationRecord>>(
      stream: repository.watchQuotations(userId),
      builder: (context, quoteSnap) {
        return StreamBuilder<List<OrderRecord>>(
          stream: repository.watchOrders(userId),
          builder: (context, orderSnap) {
            final now = DateTime.now().millisecondsSinceEpoch;
            final quotes = quoteSnap.data ?? const <QuotationRecord>[];
            final orders = orderSnap.data ?? const <OrderRecord>[];

            // A quotation whose follow-up date has passed is a decision the
            // user is sitting on, not a record.
            final chase = quotes
                .where((q) => q.followUpDateMs > 0 && q.followUpDateMs <= now)
                .toList(growable: false)
              ..sort((a, b) => a.followUpDateMs.compareTo(b.followUpDateMs));

            final pending = orders
                .where((o) => o.status.toLowerCase() != 'dispatched')
                .toList(growable: false);
            final stale = pending
                .where(
                  (o) =>
                      now - o.createdAtMs >
                      const Duration(days: 7).inMilliseconds,
                )
                .toList(growable: false);

            if (chase.isEmpty && stale.isEmpty) {
              return const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AivySectionHeader(title: 'Needs attention'),
                  AivyCard(child: AivyEmpty('Nothing pending a decision.')),
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AivySectionHeader(
                  title: 'Needs attention',
                  count: chase.length + stale.length,
                  action: 'See all',
                  onAction: onSeeAll,
                ),
                if (chase.isNotEmpty)
                  AivyCard(
                    accent: AivyUi.warn,
                    onTap: onSeeAll,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.request_quote_outlined,
                              size: 16,
                              color: AivyUi.warn,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${chase.length} quotation follow-ups due',
                              style: AivyUi.body(context)
                                  .copyWith(fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        ...chase.take(3).map(
                              (q) => Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        q.clientName?.trim().isNotEmpty == true
                                            ? q.clientName!
                                            : 'Unnamed client',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: AivyUi.soft(context),
                                      ),
                                    ),
                                    Text(
                                      AivyUi.inrExact(q.amount),
                                      style: AivyUi.soft(context).copyWith(
                                        color: AivyUi.ink,
                                        fontFeatures: AivyUi.tabular,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                      ],
                    ),
                  ),
                if (chase.isNotEmpty && stale.isNotEmpty)
                  const SizedBox(height: AivyUi.gap),
                if (stale.isNotEmpty)
                  AivyCard(
                    accent: AivyUi.info,
                    onTap: onSeeAll,
                    child: Row(
                      children: [
                        const Icon(
                          Icons.inventory_2_outlined,
                          size: 16,
                          color: AivyUi.info,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${stale.length} orders pending over a week',
                            style: AivyUi.body(context),
                          ),
                        ),
                        Text(
                          AivyUi.inr(
                            stale.fold<double>(0, (a, o) => a + o.amount),
                          ),
                          style: AivyUi.body(context).copyWith(
                            fontWeight: FontWeight.w600,
                            fontFeatures: AivyUi.tabular,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// This week
// ---------------------------------------------------------------------------

class _WeekSection extends StatelessWidget {
  const _WeekSection({required this.repository, required this.userId});

  final ChatRepository repository;
  final String userId;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1))
        .millisecondsSinceEpoch;

    return StreamBuilder<List<QuotationRecord>>(
      stream: repository.watchQuotations(userId),
      builder: (context, quoteSnap) {
        return StreamBuilder<List<OrderRecord>>(
          stream: repository.watchOrders(userId),
          builder: (context, orderSnap) {
            final quotes = (quoteSnap.data ?? const <QuotationRecord>[])
                .where((q) => q.createdAtMs >= monday)
                .toList(growable: false);
            final orders = (orderSnap.data ?? const <OrderRecord>[])
                .where((o) => o.createdAtMs >= monday)
                .toList(growable: false);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AivySectionHeader(title: 'This week'),
                Row(
                  children: [
                    Expanded(
                      child: _Stat(
                        label: 'Quotations',
                        value: '${quotes.length}',
                        sub: quotes.isEmpty
                            ? '—'
                            : AivyUi.inr(
                                quotes.fold<double>(0, (a, q) => a + q.amount),
                              ),
                        color: AivyUi.brand,
                      ),
                    ),
                    const SizedBox(width: AivyUi.gap),
                    Expanded(
                      child: _Stat(
                        label: 'Orders',
                        value: '${orders.length}',
                        sub: orders.isEmpty
                            ? '—'
                            : AivyUi.inr(
                                orders.fold<double>(0, (a, o) => a + o.amount),
                              ),
                        color: AivyUi.ok,
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.sub,
    required this.color,
  });

  final String label;
  final String value;
  final String sub;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AivyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: AivyUi.label(context)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style:
                    AivyUi.display(context).copyWith(fontSize: 26, color: color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AivyUi.soft(context)
                      .copyWith(fontFeatures: AivyUi.tabular),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ask Aivy
// ---------------------------------------------------------------------------

class _AskAivy extends StatelessWidget {
  const _AskAivy({this.onAsk});

  final VoidCallback? onAsk;

  static const List<String> _prompts = [
    'Who do I call today?',
    'Anything important?',
    'Recent quotations?',
    'How much is pending?',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AivySectionHeader(title: 'Ask Aivy'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in _prompts)
              GestureDetector(
                onTap: onAsk,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: AivyUi.surface,
                    borderRadius: BorderRadius.circular(AivyUi.radiusSm),
                    border: Border.all(color: AivyUi.line),
                  ),
                  child: Text(p, style: AivyUi.soft(context)),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 18,
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}
