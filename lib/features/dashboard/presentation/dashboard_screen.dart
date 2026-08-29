import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/aivy_theme.dart';
import '../../chat/data/aivy_process_service.dart';
import '../../chat/data/chat_repository.dart';
import '../../chat/models/chat_message.dart';
import '../../clients/data/client_repository.dart';
import '../../clients/models/client.dart';
import '../../payments/data/payment_repository.dart';
import '../../reminders/data/reminder_repository.dart';
import '../../reminders/models/reminder_item.dart';
import '../models/client_insights_summary.dart';
import '../models/order_record.dart';
import '../models/quotation_record.dart';
import '../../../services/audio_service.dart';
import 'widgets/client_insights_strip.dart';
import 'widgets/header_widget.dart';
import 'widgets/summary_card.dart';
import 'widgets/today_list.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.userId,
    this.activeChatId,
    this.onOpenChat,
    this.onOpenMeetings,
  });

  final String userId;
  final String? activeChatId;
  final VoidCallback? onOpenChat;
  final VoidCallback? onOpenMeetings;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin {
  late final ChatRepository _repository;
  late final AivyProcessService _aivyProcess;
  late final ClientRepository _clients;
  late final PaymentRepository _payments;
  late final ReminderRepository _reminders;
  late final AnimationController _orbPulse;

  String? _dispatchingOrderId;

  final NumberFormat _currency = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 0,
  );

  final DateFormat _timeFormat = DateFormat('hh:mm a');

  @override
  void initState() {
    super.initState();
    _repository = ChatRepository();
    _aivyProcess = AivyProcessService();
    _clients = ClientRepository();
    _payments = PaymentRepository(clients: _clients);
    _reminders = ReminderRepository();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_aivyProcess.syncClientStats());
      unawaited(_aivyProcess.fetchDashboardStats());
      unawaited(_reminders.syncPendingReminderNotifications(widget.userId));
      // Action Required modal disabled for now (IndexedStack mounts Dashboard off-tab).
      // Re-enable via fetchImportantRemindersAndShowIfNeeded when product wants it back.
    });
    _orbPulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _orbPulse.dispose();
    _aivyProcess.dispose();
    super.dispose();
  }

  Future<void> _markOneOrderDispatched(OrderRecord order) async {
    if (_dispatchingOrderId != null) {
      return;
    }
    final cfg = await _askDispatchConfig(order);
    if (cfg == null) {
      return;
    }
    setState(() {
      _dispatchingOrderId = order.id;
    });
    try {
      final client = await _resolveOrCreateClientForDispatch(
        (order.clientName ?? '').trim(),
      );
      if (cfg.receivedAmount > 0) {
        await _payments.settlePaymentReceived(
          userId: widget.userId,
          clientId: client.id,
          clientName: client.name,
          receivedAmount: cfg.receivedAmount,
          paymentNote: 'Order dispatch receipt',
        );
      }
      int? dueDateMs;
      if (cfg.pendingDueAmount > 0 && cfg.termDays > 0) {
        final now = DateTime.now();
        final dueDay = DateTime(
          now.year,
          now.month,
          now.day,
        ).add(Duration(days: cfg.termDays));
        dueDateMs = dueDay.millisecondsSinceEpoch;
        await _payments.createPaymentDue(
          userId: widget.userId,
          clientId: client.id,
          clientName: client.name,
          amount: cfg.pendingDueAmount,
          dueDateMs: dueDateMs,
          note: 'Order dispatch due (${cfg.termDays} days term)',
        );
        await _payments.syncClientOutstandingForClient(widget.userId, client.id);
        final reminderAt = DateTime(
          dueDay.year,
          dueDay.month,
          dueDay.day,
          11,
          0,
        );
        await _reminders.createReminder(
          userId: widget.userId,
          title: 'Payment follow-up: ${client.name}',
          scheduledAt: reminderAt,
          type: 'payment',
          subType: 'followup',
          note:
              '${_currency.format(cfg.pendingDueAmount)} due on ${DateFormat('d MMM').format(dueDay)}',
          clientName: client.name,
        );
      }
      await _repository.markOrderDispatched(
        userId: widget.userId,
        orderId: order.id,
        paymentTermDays:
            (cfg.pendingDueAmount > 0 && cfg.termDays > 0) ? cfg.termDays : null,
        paymentDueDateMs: dueDateMs,
      );
      if (mounted) {
        final parts = <String>['Order marked as dispatched.'];
        if (cfg.receivedAmount > 0) {
          parts.add('Received: ${_currency.format(cfg.receivedAmount)}');
        }
        if (cfg.pendingDueAmount > 0 && cfg.termDays > 0) {
          parts.add(
            'Pending due: ${_currency.format(cfg.pendingDueAmount)} (${cfg.termDays} days)',
          );
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(parts.join(' '))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is Exception
                  ? e.toString()
                  : 'Could not mark order as dispatched',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _dispatchingOrderId = null;
        });
      }
    }
  }

  Future<Client> _resolveOrCreateClientForDispatch(String clientName) async {
    final safe = clientName.isEmpty ? 'Client' : clientName;
    final res = await _clients.resolveForPaymentName(widget.userId, safe);
    if (res.client != null) {
      return res.client!;
    }
    if (res.candidates.isNotEmpty) {
      return res.candidates.first;
    }
    return _clients.createClient(widget.userId, safe);
  }

  Future<_DispatchConfig?> _askDispatchConfig(OrderRecord order) async {
    final dispatchCtrl = TextEditingController(
      text: order.amount > 0 ? order.amount.toStringAsFixed(0) : '',
    );
    final receivedCtrl = TextEditingController();
    final termCtrl = TextEditingController();
    var createDue = false;
    String? err;
    final result = await showDialog<_DispatchConfig>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Dispatch details'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: dispatchCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Dispatch amount',
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Create payment due'),
                      value: createDue,
                      onChanged: (v) => setLocal(() {
                        createDue = v;
                        err = null;
                      }),
                    ),
                    if (!createDue) ...[
                      TextField(
                        controller: receivedCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Received amount',
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    TextField(
                      controller: termCtrl,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: createDue
                            ? 'Payment term days'
                            : 'Payment term days (required if pending remains)',
                      ),
                    ),
                    if (err != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        err!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final dispatch = double.tryParse(
                      dispatchCtrl.text.trim().replaceAll(RegExp(r'[₹,\s]'), ''),
                    );
                    final received = double.tryParse(
                          receivedCtrl.text.trim().replaceAll(
                            RegExp(r'[₹,\s]'),
                            '',
                          ),
                        ) ??
                        0;
                    final days = int.tryParse(termCtrl.text.trim()) ?? 0;
                    if (dispatch == null || dispatch <= 0) {
                      setLocal(() => err = 'Valid dispatch amount required.');
                      return;
                    }
                    if (createDue) {
                      if (days <= 0) {
                        setLocal(() => err = 'Payment term days required.');
                        return;
                      }
                      Navigator.of(ctx).pop(
                        _DispatchConfig(
                          dispatchAmount: dispatch,
                          receivedAmount: 0,
                          pendingDueAmount: dispatch,
                          termDays: days,
                        ),
                      );
                      return;
                    }
                    if (received <= 0) {
                      setLocal(() => err = 'Received amount required.');
                      return;
                    }
                    final pending = dispatch - received;
                    if (pending > 0 && days <= 0) {
                      setLocal(() => err = 'Pending ke liye term days required.');
                      return;
                    }
                    Navigator.of(ctx).pop(
                      _DispatchConfig(
                        dispatchAmount: dispatch,
                        receivedAmount: received,
                        pendingDueAmount: pending > 0 ? pending : 0,
                        termDays: pending > 0 ? days : 0,
                      ),
                    );
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
    dispatchCtrl.dispose();
    receivedCtrl.dispose();
    termCtrl.dispose();
    return result;
  }

int _quotationCount(List<QuotationRecord> quotes) => quotes.length;

  double _totalValue(List<QuotationRecord> quotes) {
    var sum = 0.0;
    for (final q in quotes) {
      sum += q.amount;
    }
    return sum;
  }

  bool _isToday(
    int scheduledMs,
    DateTime startOfToday,
    DateTime startOfTomorrow,
  ) {
    final t = DateTime.fromMillisecondsSinceEpoch(scheduledMs);
    return !t.isBefore(startOfToday) && t.isBefore(startOfTomorrow);
  }

  List<TodayGlanceRow> _todayReminderRows(
    List<ReminderItem> reminders,
    DateTime startOfToday,
    DateTime startOfTomorrow,
  ) {
    final rows = <TodayGlanceRow>[];
    for (final r in reminders) {
      if (r.status != 'pending') {
        continue;
      }
      if (_isToday(r.scheduledTimeMs, startOfToday, startOfTomorrow)) {
        rows.add(
          TodayGlanceRow(
            title: r.displayTitle,
            timeLabel: _timeFormat.format(
              DateTime.fromMillisecondsSinceEpoch(r.scheduledTimeMs),
            ),
            indicatorColor: const Color(0xFF22D3EE),
          ),
        );
      }
    }
    return rows;
  }

  List<TodayGlanceRow> _overdueFollowUpRows(
    List<ReminderItem> followUps,
    DateTime startOfToday,
  ) {
    final rows = <TodayGlanceRow>[];
    for (final r in followUps) {
      if (!r.isFollowUp || r.status != 'pending') {
        continue;
      }
      if (r.scheduledTimeMs < startOfToday.millisecondsSinceEpoch) {
        rows.add(
          TodayGlanceRow(
            title: r.displayTitle,
            timeLabel: _timeFormat.format(
              DateTime.fromMillisecondsSinceEpoch(r.scheduledTimeMs),
            ),
            indicatorColor: const Color(0xFFF97316),
          ),
        );
      }
    }
    return rows;
  }

  Widget _fadeSlide({required int index, required Widget child}) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: 420 + (index * 50).clamp(0, 300)),
      curve: Curves.easeOutCubic,
      builder: (context, t, c) {
        final eased = t.clamp(0.0, 1.0);
        return Opacity(
          opacity: eased,
          child: Transform.translate(
            offset: Offset(0, (1 - eased) * 12),
            child: c,
          ),
        );
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AivyTheme.darkDashboard(),
      child: Builder(
        builder: (context) {
          final now = DateTime.now();
          final startOfToday = DateTime(now.year, now.month, now.day);
          final startOfTomorrow = startOfToday.add(const Duration(days: 1));

          final bottomPad = MediaQuery.paddingOf(context).bottom + 96;

          return SizedBox.expand(
            child: Stack(
              clipBehavior: Clip.none,
              fit: StackFit.expand,
              children: [
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF0A0A0F), Color(0xFF121826)],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 48,
                  left: -24,
                  right: -24,
                  height: 320,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(0.55, -0.15),
                          radius: 1.05,
                          colors: [
                            const Color(0xFF6366F1).withValues(alpha: 0.26),
                            const Color(0xFF2563EB).withValues(alpha: 0.12),
                            const Color(0xFF0A0A0F).withValues(alpha: 0),
                          ],
                          stops: const [0.0, 0.35, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPad),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _fadeSlide(
                          index: 0,
                          child: DashboardHeader(
                            onMeetingsPressed: widget.onOpenMeetings,
                            onNotificationsPressed: () {},
                            onProfilePressed: () {},
                          ),
                        ),
                        const SizedBox(height: 12),
                        StreamBuilder<ClientInsightsSummary?>(
                          stream: _repository.watchClientInsights(
                            widget.userId,
                          ),
                          builder: (context, iSnap) {
                            final i = iSnap.data;
                            if (i == null) {
                              return const SizedBox.shrink();
                            }
                            return _fadeSlide(
                              index: 1,
                              child: ClientInsightsStrip(data: i),
                            );
                          },
                        ),
                        const SizedBox(height: 20),
                        _fadeSlide(
                          index: 2,
                          child: _HeroSection(orbPulse: _orbPulse),
                        ),
                        const SizedBox(height: 22),
                        StreamBuilder<List<QuotationRecord>>(
                          stream: _repository.watchQuotations(widget.userId),
                          builder: (context, qSnap) {
                            final quotes =
                                qSnap.data ?? const <QuotationRecord>[];
                            final quotationCount = _quotationCount(quotes);
                            final totalVal = _totalValue(quotes);
                            final totalLabel = _currency.format(totalVal);

                            return StreamBuilder<List<ReminderItem>>(
                              stream: _repository.watchUpcomingReminders(
                                widget.userId,
                              ),
                              builder: (context, rSnap) {
                                final reminders =
                                    rSnap.data ?? const <ReminderItem>[];
                                final todayReminderRows = _todayReminderRows(
                                  reminders,
                                  startOfToday,
                                  startOfTomorrow,
                                );

                                return StreamBuilder<List<ReminderItem>>(
                                  stream: _repository.watchPendingFollowUps(
                                    widget.userId,
                                  ),
                                  builder: (context, fSnap) {
                                    final followUps =
                                        fSnap.data ?? const <ReminderItem>[];
                                    final followUpCount = followUps
                                        .where((r) => r.status == 'pending')
                                        .length;
                                    final overdueRows = _overdueFollowUpRows(
                                      followUps,
                                      startOfToday,
                                    );

                                    final loading =
                                        !qSnap.hasData ||
                                        !rSnap.hasData ||
                                        !fSnap.hasData;

                                    if (qSnap.hasError) {
                                      return Text('${qSnap.error}');
                                    }
                                    if (rSnap.hasError) {
                                      return Text('${rSnap.error}');
                                    }
                                    if (fSnap.hasError) {
                                      return Text('${fSnap.error}');
                                    }

                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        if (loading)
                                          const Center(
                                            child: Padding(
                                              padding: EdgeInsets.all(24),
                                              child:
                                                  CircularProgressIndicator(),
                                            ),
                                          )
                                        else ...[
                                          LayoutBuilder(
                                            builder: (context, constraints) {
                                              final w = constraints.maxWidth;
                                              if (w >= 520) {
                                                return Row(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Expanded(
                                                      child: _fadeSlide(
                                                        index: 2,
                                                        child: DashboardSummaryCard(
                                                          variant:
                                                              SummaryCardVariant
                                                                  .quotation,
                                                          title: 'QUOTATIONS',
                                                          value:
                                                              '$quotationCount',
                                                          subtitle: 'Total',
                                                          icon: Icons
                                                              .request_quote_rounded,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 12),
                                                    Expanded(
                                                      child: _fadeSlide(
                                                        index: 3,
                                                        child: DashboardSummaryCard(
                                                          variant:
                                                              SummaryCardVariant
                                                                  .revenue,
                                                          title: 'TOTAL VALUE',
                                                          value: totalLabel,
                                                          subtitle: 'All Time',
                                                          icon: Icons
                                                              .payments_rounded,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 12),
                                                    Expanded(
                                                      child: _fadeSlide(
                                                        index: 4,
                                                        child: DashboardSummaryCard(
                                                          variant:
                                                              SummaryCardVariant
                                                                  .followUp,
                                                          title: 'FOLLOW-UPS',
                                                          value:
                                                              '$followUpCount',
                                                          subtitle: 'Pending',
                                                          icon: Icons
                                                              .phone_callback_rounded,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                );
                                              }
                                              return Column(
                                                children: [
                                                  _fadeSlide(
                                                    index: 2,
                                                    child: DashboardSummaryCard(
                                                      variant:
                                                          SummaryCardVariant
                                                              .quotation,
                                                      title: 'QUOTATIONS',
                                                      value: '$quotationCount',
                                                      subtitle: 'Total',
                                                      icon: Icons
                                                          .request_quote_rounded,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 12),
                                                  _fadeSlide(
                                                    index: 3,
                                                    child: DashboardSummaryCard(
                                                      variant:
                                                          SummaryCardVariant
                                                              .revenue,
                                                      title: 'TOTAL VALUE',
                                                      value: totalLabel,
                                                      subtitle: 'All Time',
                                                      icon: Icons
                                                          .payments_rounded,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 12),
                                                  _fadeSlide(
                                                    index: 4,
                                                    child: DashboardSummaryCard(
                                                      variant:
                                                          SummaryCardVariant
                                                              .followUp,
                                                      title: 'FOLLOW-UPS',
                                                      value: '$followUpCount',
                                                      subtitle: 'Pending',
                                                      icon: Icons
                                                          .phone_callback_rounded,
                                                    ),
                                                  ),
                                                ],
                                              );
                                            },
                                          ),
                                          const SizedBox(height: 20),
                                          StreamBuilder<List<OrderRecord>>(
                                            stream: _repository.watchOrders(
                                              widget.userId,
                                            ),
                                            builder: (context, oSnap) {
                                              final orders =
                                                  oSnap.data ?? const <OrderRecord>[];
                                              if (oSnap.hasError) {
                                                return Text('${oSnap.error}');
                                              }
                                              final startOfMonth = DateTime(
                                                now.year,
                                                now.month,
                                                1,
                                              );
                                              final endOfMonthExclusive = DateTime(
                                                now.year,
                                                now.month + 1,
                                                1,
                                              );
                                              final m = OrderDashMetrics.compute(
                                                orders,
                                                startOfToday: startOfToday,
                                                startOfNextDay: startOfTomorrow,
                                                startOfMonth: startOfMonth,
                                                endOfMonthExclusive:
                                                    endOfMonthExclusive,
                                              );
                                              final pendingSorted = orders
                                                  .where((o) => o.isPending)
                                                  .toList()
                                                ..sort(
                                                  (a, b) => a.createdAtMs
                                                      .compareTo(b.createdAtMs),
                                                );
                                              return Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                children: [
                                                  LayoutBuilder(
                                                    builder: (context, c) {
                                                      final w = c.maxWidth;
                                                      if (w >= 720) {
                                                        return Row(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            Expanded(
                                                              child: _fadeSlide(
                                                                index: 5,
                                                                child: DashboardSummaryCard(
                                                                  variant:
                                                                      SummaryCardVariant
                                                                          .order,
                                                                  title: 'ORDERS TODAY',
                                                                  value:
                                                                      '${m.ordersToday}',
                                                                  subtitle: 'Count',
                                                                  icon: Icons
                                                                      .shopping_bag_outlined,
                                                                ),
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              width: 8,
                                                            ),
                                                            Expanded(
                                                              child: _fadeSlide(
                                                                index: 5,
                                                                child: DashboardSummaryCard(
                                                                  variant:
                                                                      SummaryCardVariant
                                                                          .order,
                                                                  title:
                                                                      'ORDERS (MONTH)',
                                                                  value:
                                                                      '${m.ordersThisMonth}',
                                                                  subtitle: 'Count',
                                                                  icon: Icons
                                                                      .calendar_month_rounded,
                                                                ),
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              width: 8,
                                                            ),
                                                            Expanded(
                                                              child: _fadeSlide(
                                                                index: 5,
                                                                child: DashboardSummaryCard(
                                                                  variant:
                                                                      SummaryCardVariant
                                                                          .order,
                                                                  title: 'PENDING',
                                                                  value:
                                                                      '${m.pendingCount}',
                                                                  subtitle: 'Orders',
                                                                  icon: Icons
                                                                      .pending_actions_rounded,
                                                                ),
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              width: 8,
                                                            ),
                                                            Expanded(
                                                              child: _fadeSlide(
                                                                index: 5,
                                                                child: DashboardSummaryCard(
                                                                  variant:
                                                                      SummaryCardVariant
                                                                          .order,
                                                                  title:
                                                                      'DISPATCH TODAY',
                                                                  value:
                                                                      '${m.dispatchToday}',
                                                                  subtitle: 'Count',
                                                                  icon: Icons
                                                                      .local_shipping_rounded,
                                                                ),
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              width: 8,
                                                            ),
                                                            Expanded(
                                                              child: _fadeSlide(
                                                                index: 5,
                                                                child: DashboardSummaryCard(
                                                                  variant:
                                                                      SummaryCardVariant
                                                                          .order,
                                                                  title:
                                                                      'DISPATCH (MONTH)',
                                                                  value:
                                                                      '${m.dispatchThisMonth}',
                                                                  subtitle: 'Count',
                                                                  icon: Icons
                                                                      .rocket_launch_outlined,
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                        );
                                                      }
                                                      return Wrap(
                                                        spacing: 10,
                                                        runSpacing: 10,
                                                        children: [
                                                          SizedBox(
                                                            width: (w - 10) / 2,
                                                            child: _fadeSlide(
                                                              index: 5,
                                                              child: DashboardSummaryCard(
                                                                variant:
                                                                    SummaryCardVariant
                                                                        .order,
                                                                title: 'ORDERS TODAY',
                                                                value:
                                                                    '${m.ordersToday}',
                                                                subtitle: 'Count',
                                                                icon: Icons
                                                                    .shopping_bag_outlined,
                                                              ),
                                                            ),
                                                          ),
                                                          SizedBox(
                                                            width: (w - 10) / 2,
                                                            child: _fadeSlide(
                                                              index: 5,
                                                              child: DashboardSummaryCard(
                                                                variant:
                                                                    SummaryCardVariant
                                                                        .order,
                                                                title:
                                                                    'ORDERS (MONTH)',
                                                                value:
                                                                    '${m.ordersThisMonth}',
                                                                subtitle: 'Count',
                                                                icon: Icons
                                                                    .calendar_month_rounded,
                                                              ),
                                                            ),
                                                          ),
                                                          SizedBox(
                                                            width: (w - 10) / 2,
                                                            child: _fadeSlide(
                                                              index: 5,
                                                              child: DashboardSummaryCard(
                                                                variant:
                                                                    SummaryCardVariant
                                                                        .order,
                                                                title: 'PENDING',
                                                                value:
                                                                    '${m.pendingCount}',
                                                                subtitle: 'Orders',
                                                                icon: Icons
                                                                    .pending_actions_rounded,
                                                              ),
                                                            ),
                                                          ),
                                                          SizedBox(
                                                            width: (w - 10) / 2,
                                                            child: _fadeSlide(
                                                              index: 5,
                                                              child: DashboardSummaryCard(
                                                                variant:
                                                                    SummaryCardVariant
                                                                        .order,
                                                                title:
                                                                    'DISPATCH TODAY',
                                                                value:
                                                                    '${m.dispatchToday}',
                                                                subtitle: 'Count',
                                                                icon: Icons
                                                                    .local_shipping_rounded,
                                                              ),
                                                            ),
                                                          ),
                                                          SizedBox(
                                                            width: (w - 10) / 2,
                                                            child: _fadeSlide(
                                                              index: 5,
                                                              child: DashboardSummaryCard(
                                                                variant:
                                                                    SummaryCardVariant
                                                                        .order,
                                                                title:
                                                                    'DISPATCH (MONTH)',
                                                                value:
                                                                    '${m.dispatchThisMonth}',
                                                                subtitle: 'Count',
                                                                icon: Icons
                                                                    .rocket_launch_outlined,
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      );
                                                    },
                                                  ),
                                                  if (pendingSorted
                                                      .isNotEmpty) ...[
                                                    const SizedBox(height: 16),
                                                    _PendingOrdersTable(
                                                      rows: pendingSorted
                                                          .take(20)
                                                          .toList(
                                                            growable: false,
                                                          ),
                                                      currency: _currency,
                                                      onMarkDispatched:
                                                          _markOneOrderDispatched,
                                                      busyOrderId:
                                                          _dispatchingOrderId,
                                                    ),
                                                  ],
                                                ],
                                              );
                                            },
                                          ),
                                          const SizedBox(height: 20),
                                          _fadeSlide(
                                            index: 5,
                                            child: TodayAtGlanceList(
                                              todayReminders: todayReminderRows,
                                              overdueFollowUps: overdueRows,
                                            ),
                                          ),
                                        ],
                                      ],
                                    );
                                  },
                                );
                              },
                            );
                          },
                        ),
                        const SizedBox(height: 16),
                        // The command bar that used to sit here ran the old
                        // chat flow. Typing now belongs to the Aivy tab, which
                        // understands plain speech instead of set commands.
                        _fadeSlide(
                          index: 6,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: ElevatedButton(
                              onPressed: () async {
                                await AudioService.playReminder();
                              },
                              child: const Text('Test Ringtone'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _HeroSection extends StatelessWidget {
  const _HeroSection({required this.orbPulse});

  final AnimationController orbPulse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headline = theme.textTheme.headlineMedium?.copyWith(
      height: 1.12,
      letterSpacing: -0.6,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 0,
                runSpacing: 6,
                children: [
                  Text(
                    "I'm Aivy, ",
                    style: headline?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w800,
                      fontSize: 28,
                    ),
                  ),
                  ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (bounds) => const LinearGradient(
                      colors: [
                        Color(0xFFE9D5FF),
                        Color(0xFFA78BFA),
                        Color(0xFF38BDF8),
                        Color(0xFF22D3EE),
                      ],
                    ).createShader(bounds),
                    child: Text(
                      'Ready',
                      style: headline?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        fontSize: 28,
                      ),
                    ),
                  ),
                  Text(
                    ' to Power ',
                    style: headline?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w800,
                      fontSize: 28,
                    ),
                  ),
                  ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (bounds) => const LinearGradient(
                      colors: [
                        Color(0xFF93C5FD),
                        Color(0xFF22D3EE),
                        Color(0xFF2DD4BF),
                      ],
                    ).createShader(bounds),
                    child: Text(
                      'Your Day',
                      style: headline?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        fontSize: 28,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                'Just type or speak. I’ll handle the rest.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.45,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        AnimatedBuilder(
          animation: orbPulse,
          builder: (context, child) {
            final t = Curves.easeInOut.transform(orbPulse.value);
            final pulse = 1.04 + t * 0.06;
            return Transform.scale(
              scale: pulse,
              child: Container(
                width: 118,
                height: 118,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(
                        0xFFA78BFA,
                      ).withValues(alpha: 0.42 + t * 0.12),
                      blurRadius: 28 + t * 10,
                      spreadRadius: t * 4,
                    ),
                    BoxShadow(
                      color: const Color(
                        0xFF22D3EE,
                      ).withValues(alpha: 0.38 + t * 0.1),
                      blurRadius: 36 + t * 8,
                      spreadRadius: -6,
                    ),
                    BoxShadow(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.3),
                      blurRadius: 18,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: child,
              ),
            );
          },
          child: Container(
            width: 118,
            height: 118,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  Color(0xFFF5F3FF),
                  Color(0xFF8B5CF6),
                  Color(0xFF4F46E5),
                  Color(0xFF0284C7),
                ],
                stops: [0.0, 0.32, 0.62, 1.0],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PendingOrdersTable extends StatelessWidget {
  const _PendingOrdersTable({
    required this.rows,
    required this.currency,
    this.onMarkDispatched,
    this.busyOrderId,
  });

  final List<OrderRecord> rows;
  final NumberFormat currency;
  final Future<void> Function(OrderRecord order)? onMarkDispatched;
  final String? busyOrderId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateFmt = DateFormat('d MMM');
    const radius = 20.0;
    final showAction = onMarkDispatched != null;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: const Color(0xFF131520),
        border: Border.all(
          color: const Color(0xFF2D3A4F).withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PENDING ORDERS',
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          _TableLine(
            isHeader: true,
            left: 'Client',
            mid: 'Amount',
            right: 'Date',
            showAction: showAction,
            actionHeader: 'Dispatch',
            theme: theme,
          ),
          const Divider(height: 1, color: Color(0xFF2D3A4F)),
          for (final o in rows) ...[
            const SizedBox(height: 6),
            _TableLine(
              isHeader: false,
              left: _clientWithStage(o),
              mid: currency.format(o.amount),
              right: o.createdAtMs > 0
                  ? dateFmt.format(
                      DateTime.fromMillisecondsSinceEpoch(o.createdAtMs),
                    )
                  : '—',
              showAction: showAction,
              theme: theme,
              action: showAction
                  ? (busyOrderId == o.id
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF22D3EE),
                            ),
                          )
                        : TextButton(
                            onPressed: busyOrderId != null
                                ? null
                                : () {
                                    unawaited(onMarkDispatched!(o));
                                  },
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 0,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text(
                              'Mark',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF34D399),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ))
                  : null,
            ),
          ],
        ],
      ),
    );
  }

  String _clientWithStage(OrderRecord o) {
    final client = o.clientName?.trim().isNotEmpty == true
        ? o.clientName!.trim()
        : '—';
    final stage = _stageLabel(o.processStage);
    if (stage == null) {
      return client;
    }
    return '$client • $stage';
  }

  String? _stageLabel(String? raw) {
    final s = (raw ?? '').trim().toLowerCase();
    if (s.isEmpty) {
      return null;
    }
    switch (s) {
      case 'plate_received':
        return 'Plate';
      case 'printing_done':
        return 'Printing';
      case 'punching_done':
        return 'Punching';
      case 'material_ready':
        return 'Material';
      default:
        return null;
    }
  }
}

class _TableLine extends StatelessWidget {
  const _TableLine({
    required this.isHeader,
    required this.left,
    required this.mid,
    required this.right,
    required this.showAction,
    this.action,
    this.actionHeader,
    required this.theme,
  });

  final bool isHeader;
  final String left;
  final String mid;
  final String right;
  final bool showAction;
  final Widget? action;
  final String? actionHeader;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final style = (isHeader
            ? theme.textTheme.labelSmall
            : theme.textTheme.bodyMedium)
        ?.copyWith(
          color: isHeader
              ? const Color(0xFF94A3B8)
              : const Color(0xFFE2E8F0),
          fontWeight: isHeader ? FontWeight.w700 : FontWeight.w500,
        );
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Text(
            left,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        Expanded(
          flex: 2,
          child: Text(mid, style: style),
        ),
        Expanded(
          flex: 2,
          child: Text(
            right,
            textAlign: TextAlign.end,
            style: style,
          ),
        ),
        if (showAction)
          SizedBox(
            width: 72,
            child: isHeader
                ? Text(
                    actionHeader ?? '',
                    textAlign: TextAlign.end,
                    style: style,
                  )
                : Align(alignment: Alignment.centerRight, child: action!),
          ),
      ],
    );
  }
}

class _DispatchConfig {
  const _DispatchConfig({
    required this.dispatchAmount,
    required this.receivedAmount,
    required this.pendingDueAmount,
    required this.termDays,
  });

  final double dispatchAmount;
  final double receivedAmount;
  final double pendingDueAmount;
  final int termDays;
}
