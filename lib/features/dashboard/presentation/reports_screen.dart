import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/design/aivy_ui.dart';
import '../../chat/data/chat_repository.dart';
import '../../clients/data/client_repository.dart';
import '../../payments/data/payment_repository.dart';
import '../../payments/models/client_pending_dues_summary.dart';
import '../../payments/models/payment_record.dart';
import '../../reminders/models/reminder_item.dart';
import '../../tasks/models/task_item.dart';
import '../models/order_record.dart';
import '../models/quotation_record.dart';

/// Everything that has been recorded, searchable.
///
/// Dashboard answers "what needs me now"; this answers "what happened" — so
/// nothing here duplicates it. The old version showed today's reminders and
/// pending totals as well, which meant two screens disagreeing about which was
/// the real one.
///
/// One search box filters every section at once, because a name is how anyone
/// actually looks for a record — you remember the client, not which tab they
/// were filed under.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({
    super.key,
    required this.userId,
    this.onOpenChat,
  });

  final String userId;
  final VoidCallback? onOpenChat;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

enum _Lens { all, money, orders, quotes, work }

class _ReportsScreenState extends State<ReportsScreen> {
  late final ChatRepository _repository;
  late final ClientRepository _clients;
  late final PaymentRepository _payments;

  final TextEditingController _search = TextEditingController();
  _Lens _lens = _Lens.all;
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _repository = ChatRepository();
    _clients = ClientRepository();
    _payments = PaymentRepository(clients: _clients);
    _search.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _q => _search.text.trim().toLowerCase();

  bool _matches(List<String?> fields) {
    if (_q.isEmpty) {
      return true;
    }
    return fields.any((f) => (f ?? '').toLowerCase().contains(_q));
  }

  bool _shows(_Lens lens) => _lens == _Lens.all || _lens == lens;

  Future<void> _finish(String id, Future<void> Function() action) async {
    if (_busy.contains(id)) {
      return;
    }
    setState(() => _busy.add(id));
    try {
      await action();
    } catch (e) {
      debugPrint('Reports: action on $id failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update. Try again.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy.remove(id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AivyUi.bg,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(
              controller: _search,
              lens: _lens,
              onLens: (l) => setState(() => _lens = l),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 28),
                children: [
                  if (_shows(_Lens.money)) ...[
                    _MoneyRecords(
                      payments: _payments,
                      userId: widget.userId,
                      matches: _matches,
                    ),
                    const SizedBox(height: 22),
                  ],
                  if (_shows(_Lens.orders)) ...[
                    _OrderRecords(
                      repository: _repository,
                      userId: widget.userId,
                      matches: _matches,
                    ),
                    const SizedBox(height: 22),
                  ],
                  if (_shows(_Lens.quotes)) ...[
                    _QuotationRecords(
                      repository: _repository,
                      userId: widget.userId,
                      matches: _matches,
                    ),
                    const SizedBox(height: 22),
                  ],
                  if (_shows(_Lens.work)) ...[
                    _WorkRecords(
                      repository: _repository,
                      userId: widget.userId,
                      matches: _matches,
                      busy: _busy,
                      onFinish: _finish,
                    ),
                    const SizedBox(height: 22),
                  ],
                  if (widget.onOpenChat != null)
                    Center(
                      child: TextButton.icon(
                        onPressed: widget.onOpenChat,
                        icon: const Icon(Icons.auto_awesome, size: 16),
                        label: const Text('Ask Aivy'),
                        style: TextButton.styleFrom(
                          foregroundColor: AivyUi.brand,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header: title, search, lens
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.controller,
    required this.lens,
    required this.onLens,
  });

  final TextEditingController controller;
  final _Lens lens;
  final ValueChanged<_Lens> onLens;

  static const Map<_Lens, String> _labels = {
    _Lens.all: 'All',
    _Lens.money: 'Money',
    _Lens.orders: 'Orders',
    _Lens.quotes: 'Quotations',
    _Lens.work: 'Tasks',
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Records', style: AivyUi.title(context).copyWith(fontSize: 22)),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            style: AivyUi.body(context),
            decoration: InputDecoration(
              hintText: 'Search client, amount, anything',
              hintStyle: AivyUi.soft(context),
              prefixIcon: const Icon(Icons.search, size: 19, color: AivyUi.inkFaint),
              suffixIcon: controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 17),
                      color: AivyUi.inkFaint,
                      onPressed: controller.clear,
                    ),
              isDense: true,
              filled: true,
              fillColor: AivyUi.surface,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AivyUi.radiusSm),
                borderSide: const BorderSide(color: AivyUi.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AivyUi.radiusSm),
                borderSide: const BorderSide(color: AivyUi.line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AivyUi.radiusSm),
                borderSide: const BorderSide(color: AivyUi.brand),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final entry in _labels.entries) ...[
                  _LensChip(
                    label: entry.value,
                    selected: lens == entry.key,
                    onTap: () => onLens(entry.key),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LensChip extends StatelessWidget {
  const _LensChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AivyUi.brand.withValues(alpha: 0.18) : AivyUi.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? AivyUi.brand : AivyUi.line),
        ),
        child: Text(
          label,
          style: AivyUi.soft(context).copyWith(
            color: selected ? AivyUi.brand : AivyUi.inkSoft,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Money
// ---------------------------------------------------------------------------

class _MoneyRecords extends StatelessWidget {
  const _MoneyRecords({
    required this.payments,
    required this.userId,
    required this.matches,
  });

  final PaymentRepository payments;
  final String userId;
  final bool Function(List<String?>) matches;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ClientPendingDuesSummary>>(
      stream: payments.watchPendingDuesGroupedByClient(userId),
      builder: (context, snap) {
        final all = snap.data ?? const <ClientPendingDuesSummary>[];
        final rows = all
            .where((g) => matches([g.clientName]))
            .toList(growable: false)
          ..sort((a, b) => b.totalPending.compareTo(a.totalPending));
        final total = rows.fold<double>(0, (a, g) => a + g.totalPending);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AivySectionHeader(title: 'Pending money', count: rows.length),
            if (!snap.hasData)
              const AivyCard(child: _Loading())
            else if (rows.isEmpty)
              const AivyCard(child: AivyEmpty('No pending payments.'))
            else
              AivyCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('Total', style: AivyUi.soft(context)),
                        const Spacer(),
                        Text(
                          AivyUi.inrExact(total),
                          style: AivyUi.title(context)
                              .copyWith(fontFeatures: AivyUi.tabular),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    for (final g in rows) _ClientDues(group: g),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ClientDues extends StatelessWidget {
  const _ClientDues({required this.group});

  final ClientPendingDuesSummary group;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final overdue = group.dues.where((d) {
      final due = d.dueDateMs;
      return due != null && due < now;
    }).length;

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: 4, bottom: 6),
        iconColor: AivyUi.inkFaint,
        collapsedIconColor: AivyUi.inkFaint,
        title: Row(
          children: [
            Expanded(
              child: Text(
                group.clientName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AivyUi.body(context),
              ),
            ),
            if (overdue > 0) ...[
              AivyPill('$overdue overdue', color: AivyUi.danger),
              const SizedBox(width: 8),
            ],
            Text(
              AivyUi.inrExact(group.totalPending),
              style: AivyUi.body(context).copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: AivyUi.tabular,
              ),
            ),
          ],
        ),
        children: [
          for (final d in group.dues) _DueRow(record: d),
        ],
      ),
    );
  }
}

class _DueRow extends StatelessWidget {
  const _DueRow({required this.record});

  final PaymentRecord record;

  @override
  Widget build(BuildContext context) {
    final due = record.dueDateMs;
    final left = record.remainingAmount ?? record.amount ?? 0;
    final isLate = due != null && due < DateTime.now().millisecondsSinceEpoch;
    final when = due == null
        ? 'No due date'
        : DateFormat('d MMM yyyy').format(DateTime.fromMillisecondsSinceEpoch(due));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            isLate ? Icons.error_outline : Icons.schedule,
            size: 14,
            color: isLate ? AivyUi.danger : AivyUi.inkFaint,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              record.invoiceLabel?.trim().isNotEmpty == true
                  ? '${record.invoiceLabel} · $when'
                  : when,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AivyUi.soft(context),
            ),
          ),
          Text(
            AivyUi.inrExact(left),
            style: AivyUi.soft(context).copyWith(
              color: isLate ? AivyUi.danger : AivyUi.ink,
              fontFeatures: AivyUi.tabular,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Orders
// ---------------------------------------------------------------------------

class _OrderRecords extends StatelessWidget {
  const _OrderRecords({
    required this.repository,
    required this.userId,
    required this.matches,
  });

  final ChatRepository repository;
  final String userId;
  final bool Function(List<String?>) matches;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<OrderRecord>>(
      stream: repository.watchOrders(userId),
      builder: (context, snap) {
        final all = snap.data ?? const <OrderRecord>[];
        final rows = all
            .where((o) => matches([o.clientName, o.status, o.processStage]))
            .toList(growable: false);
        final pending = rows
            .where((o) => o.status.toLowerCase() != 'dispatched')
            .toList(growable: false);
        final dispatched = rows.length - pending.length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AivySectionHeader(title: 'Orders', count: rows.length),
            if (!snap.hasData)
              const AivyCard(child: _Loading())
            else if (rows.isEmpty)
              const AivyCard(child: AivyEmpty('No orders found.'))
            else
              AivyCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        AivyPill('${pending.length} pending',
                            color: AivyUi.warn),
                        const SizedBox(width: 8),
                        AivyPill('$dispatched dispatched', color: AivyUi.ok),
                        const Spacer(),
                        Text(
                          AivyUi.inr(
                            pending.fold<double>(0, (a, o) => a + o.amount),
                          ),
                          style: AivyUi.body(context).copyWith(
                            fontWeight: FontWeight.w600,
                            fontFeatures: AivyUi.tabular,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    for (final o in rows.take(25)) _OrderRow(order: o),
                    if (rows.length > 25)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '+${rows.length - 25} more — use search above',
                          style: AivyUi.soft(context),
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

class _OrderRow extends StatelessWidget {
  const _OrderRow({required this.order});

  final OrderRecord order;

  @override
  Widget build(BuildContext context) {
    final done = order.status.toLowerCase() == 'dispatched';
    final at = DateTime.fromMillisecondsSinceEpoch(order.createdAtMs);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: done ? AivyUi.ok : AivyUi.warn,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.clientName?.trim().isNotEmpty == true
                      ? order.clientName!
                      : 'Unnamed client',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AivyUi.body(context),
                ),
                const SizedBox(height: 2),
                Text(
                  order.processStage?.trim().isNotEmpty == true
                      ? '${DateFormat('d MMM').format(at)} · ${order.processStage}'
                      : DateFormat('d MMM').format(at),
                  style: AivyUi.soft(context),
                ),
              ],
            ),
          ),
          Text(
            AivyUi.inrExact(order.amount),
            style: AivyUi.body(context)
                .copyWith(fontFeatures: AivyUi.tabular),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Quotations
// ---------------------------------------------------------------------------

class _QuotationRecords extends StatelessWidget {
  const _QuotationRecords({
    required this.repository,
    required this.userId,
    required this.matches,
  });

  final ChatRepository repository;
  final String userId;
  final bool Function(List<String?>) matches;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<QuotationRecord>>(
      stream: repository.watchQuotations(userId),
      builder: (context, snap) {
        final rows = (snap.data ?? const <QuotationRecord>[])
            .where((q) => matches([q.clientName]))
            .toList(growable: false);
        final now = DateTime.now().millisecondsSinceEpoch;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AivySectionHeader(title: 'Quotations', count: rows.length),
            if (!snap.hasData)
              const AivyCard(child: _Loading())
            else if (rows.isEmpty)
              const AivyCard(child: AivyEmpty('No quotations found.'))
            else
              AivyCard(
                child: Column(
                  children: [
                    for (final q in rows.take(25))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    q.clientName?.trim().isNotEmpty == true
                                        ? q.clientName!
                                        : 'Unnamed client',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AivyUi.body(context),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    DateFormat('d MMM yyyy').format(
                                      DateTime.fromMillisecondsSinceEpoch(
                                        q.createdAtMs,
                                      ),
                                    ),
                                    style: AivyUi.soft(context),
                                  ),
                                ],
                              ),
                            ),
                            if (q.followUpDateMs > 0 &&
                                q.followUpDateMs <= now) ...[
                              const AivyPill('Follow-up due',
                                  color: AivyUi.warn),
                              const SizedBox(width: 8),
                            ],
                            Text(
                              AivyUi.inrExact(q.amount),
                              style: AivyUi.body(context)
                                  .copyWith(fontFeatures: AivyUi.tabular),
                            ),
                          ],
                        ),
                      ),
                    if (rows.length > 25)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '+${rows.length - 25} more',
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

// ---------------------------------------------------------------------------
// Work: reminders and tasks
// ---------------------------------------------------------------------------

class _WorkRecords extends StatelessWidget {
  const _WorkRecords({
    required this.repository,
    required this.userId,
    required this.matches,
    required this.busy,
    required this.onFinish,
  });

  final ChatRepository repository;
  final String userId;
  final bool Function(List<String?>) matches;
  final Set<String> busy;
  final Future<void> Function(String, Future<void> Function()) onFinish;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ReminderItem>>(
      stream: repository.watchUpcomingReminders(userId),
      builder: (context, reminderSnap) {
        return StreamBuilder<List<TaskItem>>(
          stream: repository.watchPendingTasks(userId),
          builder: (context, taskSnap) {
            final reminders = (reminderSnap.data ?? const <ReminderItem>[])
                .where((r) => matches([r.title, r.client, r.message]))
                .toList(growable: false)
              ..sort((a, b) => a.scheduledTimeMs.compareTo(b.scheduledTimeMs));
            final tasks = (taskSnap.data ?? const <TaskItem>[])
                .where((t) => matches([t.title]))
                .toList(growable: false);

            final loading = !reminderSnap.hasData && !taskSnap.hasData;
            final total = reminders.length + tasks.length;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AivySectionHeader(title: 'Tasks & reminders', count: total),
                if (loading)
                  const AivyCard(child: _Loading())
                else if (total == 0)
                  const AivyCard(child: AivyEmpty('Nothing pending.'))
                else
                  AivyCard(
                    child: Column(
                      children: [
                        for (final r in reminders.take(30))
                          _WorkRow(
                            title: r.title.trim().isEmpty ? r.message : r.title,
                            sub: _reminderSub(r),
                            overdue: r.scheduledTimeMs <
                                DateTime.now().millisecondsSinceEpoch,
                            busy: busy.contains(r.id),
                            onDone: () => onFinish(
                              r.id,
                              () => repository.markReminderDone(
                                userId: userId,
                                reminderId: r.id,
                              ),
                            ),
                          ),
                        for (final t in tasks.take(30))
                          _WorkRow(
                            title: t.title,
                            sub: t.priority.isEmpty ? 'Task' : 'Task · ${t.priority}',
                            overdue: false,
                            busy: busy.contains(t.id),
                            onDone: () => onFinish(
                              t.id,
                              () => repository.markTaskDone(
                                userId: userId,
                                taskId: t.id,
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
      },
    );
  }

  static String _reminderSub(ReminderItem r) {
    final at = DateTime.fromMillisecondsSinceEpoch(r.scheduledTimeMs);
    final when = DateFormat('d MMM, h:mm a').format(at);
    return r.client.trim().isEmpty ? when : '$when · ${r.client}';
  }
}

class _WorkRow extends StatelessWidget {
  const _WorkRow({
    required this.title,
    required this.sub,
    required this.overdue,
    required this.busy,
    required this.onDone,
  });

  final String title;
  final String sub;
  final bool overdue;
  final bool busy;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
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
                const SizedBox(height: 2),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AivyUi.soft(context),
                      ),
                    ),
                    if (overdue) ...[
                      const SizedBox(width: 8),
                      const AivyPill('Overdue', color: AivyUi.warn),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            IconButton(
              onPressed: onDone,
              tooltip: 'Mark done',
              visualDensity: VisualDensity.compact,
              icon: const Icon(
                Icons.check_circle_outline,
                size: 20,
                color: AivyUi.inkFaint,
              ),
            ),
        ],
      ),
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
