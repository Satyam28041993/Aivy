import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../chat/data/chat_repository.dart';
import '../../payments/data/payment_repository.dart';
import '../../payments/models/client_pending_dues_summary.dart';
import '../../payments/models/payment_record.dart';
import '../../reminders/models/reminder_item.dart';
import '../../reminders/utils/reminder_grouping.dart';
import '../../tasks/models/task_item.dart';
import '../../tasks/utils/task_priority_calculator.dart';
import '../models/agent_insights.dart';
import '../models/order_record.dart';
import '../models/quotation_record.dart';
import 'reports/reports_tokens.dart';

const double _kReportsMaxContentWidth = 1120;
const double _kReportsWideBreakpoint = 960;

enum _TodayFocusKind { call, meeting, followUp, task }

class _TodayFocusItem {
  const _TodayFocusItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.reason,
    required this.whenMs,
    required this.isOverdue,
    required this.isTask,
  });

  final String id;
  final _TodayFocusKind kind;
  final String title;
  final String reason;
  final int whenMs;
  final bool isOverdue;
  final bool isTask;
}

String _ledgerBadgeFor(Map<String, dynamic> r) {
  final op = (r['lastActionType'] as String? ?? '').trim();
  final st = (r['status'] as String? ?? '').toLowerCase();
  if (op == 'payment_receipt' || st == 'received') {
    return 'Received';
  }
  if (op == 'payment_due_created' &&
      (st == 'pending' || st == 'overdue' || st == 'partial_pending')) {
    return 'Payment due';
  }
  final t = (r['type'] as String? ?? '').toLowerCase();
  if (t == 'followup') {
    return 'Follow-up';
  }
  if (op == 'reminder_created') {
    return 'Reminder';
  }
  return op.isNotEmpty ? op : 'Saved';
}

bool _ledgerMatchesKind(Map<String, dynamic> r, String kind) {
  if (kind == 'all') {
    return true;
  }
  final b = _ledgerBadgeFor(r).toLowerCase();
  switch (kind) {
    case 'reminders':
      return b.contains('reminder');
    case 'payments':
      return b.contains('payment') || b.contains('received');
    case 'followups':
      return b.contains('follow');
    case 'other':
      return !b.contains('reminder') &&
          !b.contains('payment') &&
          !b.contains('received') &&
          !b.contains('follow');
    default:
      return true;
  }
}

String _ledgerRowId(Map<String, dynamic> r, int index) {
  final id = (r['savedDocId'] as String? ?? '').trim();
  if (id.isNotEmpty) {
    return 'ledger:$id';
  }
  final ms = (r['createdAtMs'] as num?)?.toInt() ?? 0;
  return 'ledger:idx:$index:$ms';
}

/// Dense accent constants for badges, pills, and metric icons inside Reports.
class _AivyStatusColors {
  static const dueToday = Color(0xFFD97706);
  static const focusStart = Color(0xFF4F46E5);
  static const clientStart = Color(0xFF0EA5E9);
  static const remindersStart = Color(0xFF0891B2);
}

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, required this.userId, this.launchInsights});

  final String userId;

  /// Snapshot of insights computed by the launch pipeline. The dashboard
  /// uses this to render the top banner immediately before the live streams
  /// settle, then replaces it with live data.
  final AgentInsights? launchInsights;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late final ChatRepository _repository;
  late final PaymentRepository _paymentRepository;
  final DateFormat _dateFormat = DateFormat('dd MMM, hh:mm a');
  final TextEditingController _searchController = TextEditingController();
  String _categoryFilter = 'all';
  String _ledgerKindFilter = 'all';
  String _reminderScope = 'all';
  final Set<String> _selectedIds = <String>{};
  final Set<String> _completingFocusIds = <String>{};

  @override
  void initState() {
    super.initState();
    _repository = ChatRepository();
    _paymentRepository = PaymentRepository();
    _searchController.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String get _searchLower => _searchController.text.trim().toLowerCase();

  void _toggleSelected(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _clearSelection() {
    setState(_selectedIds.clear);
  }

  void _selectAllInList(Iterable<String> ids, bool select) {
    setState(() {
      if (select) {
        _selectedIds.addAll(ids);
      } else {
        _selectedIds.removeAll(ids);
      }
    });
  }

  List<TaskItem> _filterTasksBySearch(List<TaskItem> tasks) {
    final q = _searchLower;
    if (q.isEmpty) {
      return tasks;
    }
    return tasks
        .where((t) => t.title.toLowerCase().contains(q))
        .toList(growable: false);
  }

  List<ReminderItem> _filterRemindersBySearch(List<ReminderItem> items) {
    final q = _searchLower;
    if (q.isEmpty) {
      return items;
    }
    return items
        .where((r) {
          final title = buildDisplayTitle(r).toLowerCase();
          final client = r.client.toLowerCase();
          final msg = r.message.toLowerCase();
          return title.contains(q) || client.contains(q) || msg.contains(q);
        })
        .toList(growable: false);
  }

  List<Map<String, dynamic>> _filterLedgerRows(
    List<Map<String, dynamic>> rows,
  ) {
    final q = _searchLower;
    Iterable<Map<String, dynamic>> it = rows.where(
      (r) => _ledgerMatchesKind(r, _ledgerKindFilter),
    );
    if (q.isNotEmpty) {
      it = it.where((r) {
        final name = (r['clientName'] as String? ?? '').toLowerCase();
        final note = (r['note'] as String? ?? '').toLowerCase();
        final badge = _ledgerBadgeFor(r).toLowerCase();
        return name.contains(q) || note.contains(q) || badge.contains(q);
      });
    }
    return it.toList(growable: false);
  }

  List<ClientPendingDuesSummary> _filterPaymentGroups(
    List<ClientPendingDuesSummary> groups,
  ) {
    final q = _searchLower;
    if (q.isEmpty) {
      return groups;
    }
    return groups
        .where((g) => g.clientName.toLowerCase().contains(q))
        .toList(growable: false);
  }

  /// Same rules as chat `week_payment_followup_list`: any **open overdue** due
  /// plus open dues whose **due date** falls Mon–Sun this week (local clock).
  List<_WeekPaymentFollowUpEntry> _buildWeekPaymentFollowUpEntries(
    List<ClientPendingDuesSummary> groups,
    DateTime now,
  ) {
    const msPerDay = 86400000;
    final day = DateTime(now.year, now.month, now.day);
    final weekday = day.weekday;
    final weekStart = day.subtract(Duration(days: weekday - 1));
    final weekEndExclusive = weekStart.add(const Duration(days: 7));
    final weekStartMs = weekStart.millisecondsSinceEpoch;
    final weekEndMs = weekEndExclusive.millisecondsSinceEpoch;
    final nowMs = now.millisecondsSinceEpoch;
    final df = DateFormat('d MMM yyyy');

    final out = <_WeekPaymentFollowUpEntry>[];
    final seen = <String>{};

    for (final g in groups) {
      for (final p in g.dues) {
        if (!p.isOpenPaymentDue) {
          continue;
        }
        final due = p.dueDateMs;
        if (due == null || due <= 0) {
          continue;
        }
        if (!seen.add(p.id)) {
          continue;
        }
        final display = p.effectiveRemaining > 0
            ? p.effectiveRemaining
            : (p.amount ?? 0);
        if (display <= 0) {
          continue;
        }

        final overdue = due < nowMs;
        final inWeek = due >= weekStartMs && due < weekEndMs;
        final todayStart = DateTime(
          now.year,
          now.month,
          now.day,
        ).millisecondsSinceEpoch;

        /// Dashboard: overdue + iso-week + dues due in **next ~31 days**
        /// (so near-term chase lines appear; Strict chat shortcut stays narrower).
        const horizonDays = 30;
        final horizonMs = todayStart + horizonDays * msPerDay;
        final inNearTermChaseWindow = due >= todayStart && due <= horizonMs;
        if (!overdue && !inWeek && !inNearTermChaseWindow) {
          continue;
        }

        final datePart = df.format(
          DateTime.fromMillisecondsSinceEpoch(due, isUtc: false),
        );
        final int sortDaysLate;
        final String whenDetail;
        if (overdue) {
          final daysLate = math.max(1, ((nowMs - due) / msPerDay).floor());
          sortDaysLate = daysLate;
          whenDetail =
              '$datePart · $daysLate day${daysLate == 1 ? '' : 's'} delay';
        } else if (inWeek && !overdue) {
          sortDaysLate = 0;
          final daysUntil = math.max(0, ((due - nowMs) / msPerDay).ceil());
          whenDetail = daysUntil == 0
              ? '$datePart · due later today'
              : '$datePart · due in $daysUntil day'
                    '${daysUntil == 1 ? '' : 's'}';
        } else {
          sortDaysLate = 0;
          final daysUntil = math.max(0, ((due - nowMs) / msPerDay).ceil());
          whenDetail = daysUntil == 0
              ? '$datePart · due later today'
              : '$datePart · due in $daysUntil day'
                    '${daysUntil == 1 ? '' : 's'} (follow-up)';
        }

        out.add(
          _WeekPaymentFollowUpEntry(
            payment: p,
            clientName: g.clientName,
            whenDetail: whenDetail,
            sortDaysLate: sortDaysLate,
            displayAmount: display,
          ),
        );
      }
    }

    out.sort((a, b) {
      final aOver = a.sortDaysLate > 0;
      final bOver = b.sortDaysLate > 0;
      if (aOver != bOver) {
        return aOver ? -1 : 1;
      }
      if (aOver && bOver && a.sortDaysLate != b.sortDaysLate) {
        return b.sortDaysLate.compareTo(a.sortDaysLate);
      }
      final ad = a.payment.dueDateMs ?? 0;
      final bd = b.payment.dueDateMs ?? 0;
      return ad.compareTo(bd);
    });

    return out;
  }

  List<OrderRecord> _filterOrders(List<OrderRecord> orders) {
    final q = _searchLower;
    if (q.isEmpty) {
      return orders;
    }
    return orders
        .where((o) => (o.clientName ?? '').toLowerCase().contains(q))
        .toList(growable: false);
  }

  List<QuotationRecord> _filterQuotationsLastDays(
    List<QuotationRecord> raw,
    DateTime now,
    int days,
  ) {
    final cutoff =
        now.millisecondsSinceEpoch - Duration(days: days).inMilliseconds;
    return raw
        .where((q) => q.createdAtMs > 0 && q.createdAtMs >= cutoff)
        .toList(growable: false);
  }

  List<QuotationRecord> _filterQuotationsBySearch(
    List<QuotationRecord> quotes,
  ) {
    final q = _searchLower;
    if (q.isEmpty) {
      return quotes;
    }
    return quotes
        .where((r) => (r.clientName ?? '').toLowerCase().contains(q))
        .toList(growable: false);
  }

  ReminderGroupBuckets _applyReminderScope(ReminderGroupBuckets buckets) {
    switch (_reminderScope) {
      case 'overdue':
        return ReminderGroupBuckets(
          overdue: buckets.overdue,
          today: const [],
          tomorrow: const [],
          upcoming: const [],
        );
      case 'today':
        return ReminderGroupBuckets(
          overdue: const [],
          today: buckets.today,
          tomorrow: const [],
          upcoming: const [],
        );
      case 'upcoming':
        return ReminderGroupBuckets(
          overdue: const [],
          today: const [],
          tomorrow: buckets.tomorrow,
          upcoming: buckets.upcoming,
        );
      default:
        return buckets;
    }
  }

  List<_TodayFocusItem> _buildTodayFocusItems({
    required List<ReminderItem> reminders,
    required List<TaskItem> tasks,
    required DateTime now,
  }) {
    final startOfToday = DateTime(now.year, now.month, now.day);
    final startOfTomorrow = startOfToday.add(const Duration(days: 1));
    final nowMs = now.millisecondsSinceEpoch;
    final out = <_TodayFocusItem>[];

    for (final reminder in reminders) {
      if (reminder.status != 'pending') {
        continue;
      }
      final when = DateTime.fromMillisecondsSinceEpoch(
        reminder.scheduledTimeMs,
      );
      final isToday =
          !when.isBefore(startOfToday) && when.isBefore(startOfTomorrow);
      final isOverdue = reminder.scheduledTimeMs < nowMs;
      if (!isToday && !isOverdue) {
        continue;
      }
      final kind = _kindForReminder(reminder);
      out.add(
        _TodayFocusItem(
          id: 'rem:${reminder.id}',
          kind: kind,
          title: _titleForTodayReminder(reminder, kind),
          reason: _reasonForTodayReminder(reminder),
          whenMs: reminder.scheduledTimeMs,
          isOverdue: isOverdue,
          isTask: false,
        ),
      );
    }

    for (final task in tasks) {
      final due = task.dueDateMs;
      if (due == null) {
        continue;
      }
      final when = DateTime.fromMillisecondsSinceEpoch(due);
      final isToday =
          !when.isBefore(startOfToday) && when.isBefore(startOfTomorrow);
      final isOverdue =
          due < startOfToday.millisecondsSinceEpoch || (isToday && due < nowMs);
      if (!isToday && !isOverdue) {
        continue;
      }
      out.add(
        _TodayFocusItem(
          id: 'task:${task.id}',
          kind: _TodayFocusKind.task,
          title: task.title,
          reason: task.category == 'general'
              ? 'Task due today'
              : '${_capitalize(task.category)} task due today',
          whenMs: due,
          isOverdue: isOverdue,
          isTask: true,
        ),
      );
    }

    out.sort((a, b) {
      if (a.isOverdue != b.isOverdue) {
        return a.isOverdue ? -1 : 1;
      }
      return a.whenMs.compareTo(b.whenMs);
    });
    return out;
  }

  Future<void> _markTodayFocusDone(_TodayFocusItem item) async {
    if (_completingFocusIds.contains(item.id)) {
      return;
    }
    setState(() {
      _completingFocusIds.add(item.id);
    });
    try {
      final rawId = item.id.substring(item.id.indexOf(':') + 1);
      if (item.isTask) {
        await _repository.markTaskDone(userId: widget.userId, taskId: rawId);
      } else {
        await _repository.markReminderDone(
          userId: widget.userId,
          reminderId: rawId,
        );
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text('Marked done: ${item.title}'),
            duration: const Duration(seconds: 2),
          ),
        );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text('Could not mark done: $error'),
            backgroundColor: ReportsTokens.overdue(context),
            duration: const Duration(seconds: 3),
          ),
        );
    } finally {
      if (mounted) {
        setState(() {
          _completingFocusIds.remove(item.id);
        });
      }
    }
  }

  static _TodayFocusKind _kindForReminder(ReminderItem item) {
    final type = item.effectiveDocType.toLowerCase();
    final sub = (item.subType ?? '').toLowerCase();
    final raw = [
      item.title,
      item.description,
      item.message,
      item.rawInput ?? '',
      item.action ?? '',
      type,
      sub,
    ].join(' ').toLowerCase();
    if (type == 'followup' || item.isFollowUp || sub.contains('followup')) {
      return _TodayFocusKind.followUp;
    }
    if (type == 'meeting' || raw.contains('meeting')) {
      return _TodayFocusKind.meeting;
    }
    if (type == 'call' || raw.contains('call ')) {
      return _TodayFocusKind.call;
    }
    return _TodayFocusKind.task;
  }

  static String _titleForTodayReminder(
    ReminderItem item,
    _TodayFocusKind kind,
  ) {
    final client = item.client.trim();
    final base = buildDisplayTitle(item).trim();
    if (kind == _TodayFocusKind.call && client.isNotEmpty) {
      return 'Call $client';
    }
    if (kind == _TodayFocusKind.meeting && client.isNotEmpty) {
      return 'Meeting with $client';
    }
    if (kind == _TodayFocusKind.followUp && client.isNotEmpty) {
      return 'Follow up with $client';
    }
    return base.isNotEmpty ? base : item.title;
  }

  static String _reasonForTodayReminder(ReminderItem item) {
    final parts = <String>[];
    final subtitle = item.displaySubtitle.trim();
    final description = item.description.trim();
    final message = item.message.trim();
    if (subtitle.isNotEmpty) {
      parts.add(subtitle);
    } else if (description.isNotEmpty) {
      parts.add(description);
    } else if (message.isNotEmpty) {
      parts.add(message);
    }
    if (item.priority.trim().isNotEmpty &&
        item.priority.trim().toLowerCase() != 'medium') {
      parts.add('${_capitalize(item.priority)} priority');
    }
    return parts.isEmpty ? 'Scheduled for today' : parts.join(' · ');
  }

  static String _capitalize(String input) {
    if (input.isEmpty) {
      return input;
    }
    return '${input[0].toUpperCase()}${input.substring(1)}';
  }

  void _handleCategoryChanged(String next) {
    if (next == _categoryFilter) {
      return;
    }
    setState(() {
      _categoryFilter = next;
    });
  }

  List<TaskItem> _applyCategoryFilter(List<TaskItem> tasks) {
    if (_categoryFilter == 'all') {
      return tasks;
    }
    return tasks
        .where((task) => task.category == _categoryFilter)
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<TaskItem>>(
      stream: _repository.watchPendingTasks(widget.userId),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Unable to load dashboard: ${snapshot.error}',
              textAlign: TextAlign.center,
            ),
          );
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final allTasks = snapshot.data!;
        final searchedTasks = _filterTasksBySearch(allTasks);
        final taskCategoryCounts = <String, int>{
          'all': searchedTasks.length,
          'client': searchedTasks.where((t) => t.category == 'client').length,
          'work': searchedTasks.where((t) => t.category == 'work').length,
          'personal': searchedTasks
              .where((t) => t.category == 'personal')
              .length,
          'general': searchedTasks.where((t) => t.category == 'general').length,
        };
        final tasks = _applyCategoryFilter(searchedTasks);
        return StreamBuilder<List<ReminderItem>>(
          stream: _repository.watchUpcomingReminders(widget.userId),
          builder: (context, reminderSnapshot) {
            if (reminderSnapshot.hasError) {
              return Center(
                child: Text(
                  'Unable to load reminders: ${reminderSnapshot.error}',
                  textAlign: TextAlign.center,
                ),
              );
            }

            if (!reminderSnapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final remindersRaw = reminderSnapshot.data!;
            final remindersFiltered = _filterRemindersBySearch(remindersRaw);
            final now = DateTime.now();
            final bucketsFull = ReminderGrouping.partition(
              remindersFiltered,
              now,
            );
            final buckets = _applyReminderScope(bucketsFull);
            final pendingReminders = remindersFiltered
                .where((r) => r.status == 'pending')
                .toList(growable: false);

            // Priority-score ordered view of every pending task; used for the
            // general "All tasks" list.
            final prioritized = TaskPriorityCalculator.sortedByPriority(
              tasks,
              now: now,
            );

            final todayFocusItems = _buildTodayFocusItems(
              reminders: remindersRaw,
              tasks: allTasks,
              now: now,
            );
            final todaysFocusCard = _TodaysFocusTimelineCard(
              items: todayFocusItems,
              completingIds: _completingFocusIds,
              onMarkDone: _markTodayFocusDone,
            );

            final hasAppLevelWork =
                allTasks.isNotEmpty ||
                remindersRaw.any((r) => r.status == 'pending');

            return StreamBuilder<List<OrderRecord>>(
              stream: _repository.watchOrders(widget.userId),
              builder: (context, oSnap) {
                return StreamBuilder<List<ClientPendingDuesSummary>>(
                  stream: _paymentRepository.watchPendingDuesGroupedByClient(
                    widget.userId,
                  ),
                  builder: (context, paySnap) {
                    return StreamBuilder<List<Map<String, dynamic>>>(
                      stream: _repository.watchBusinessLedgerRecords(
                        widget.userId,
                      ),
                      builder: (context, ledgerSnap) {
                        final ordersRaw = oSnap.data ?? const <OrderRecord>[];
                        final groupsRaw =
                            paySnap.data ?? const <ClientPendingDuesSummary>[];
                        final ledgerRaw =
                            ledgerSnap.data ?? const <Map<String, dynamic>>[];

                        final ordersF = _filterOrders(ordersRaw);
                        final payF = _filterPaymentGroups(groupsRaw);
                        final ledgerF = _filterLedgerRows(ledgerRaw);

                        return StreamBuilder<List<QuotationRecord>>(
                          stream: _repository.watchQuotations(widget.userId),
                          builder: (context, quoteSnap) {
                            final quotesRaw =
                                quoteSnap.data ?? const <QuotationRecord>[];
                            final quotesRecent = _filterQuotationsLastDays(
                              quotesRaw,
                              now,
                              10,
                            );
                            final quotesF = _filterQuotationsBySearch(
                              quotesRecent,
                            );

                            final leftColumn = <Widget>[
                              todaysFocusCard,
                              if (ordersF.isNotEmpty) ...[
                                const SizedBox(height: 14),
                                _OrderPipelineSection(
                                  orders: ordersF,
                                  selectedIds: _selectedIds,
                                  onToggleSelected: _toggleSelected,
                                  onSelectAllInView: _selectAllInList,
                                ),
                              ],
                            ];

                            if (hasAppLevelWork) {
                              final reminderSections =
                                  ReminderGrouping.buildReportSections(
                                    buckets,
                                    now,
                                  );

                              leftColumn.add(const SizedBox(height: 14));
                              leftColumn.add(
                                _ReportsSectionCard(
                                  title: 'Reminders',
                                  subtitle: pendingReminders.isEmpty
                                      ? 'No reminders queued.'
                                      : '${pendingReminders.length} pending '
                                            '(today · tomorrow · next days). '
                                            'Tap a heading to fold or unfold.',
                                  icon: Icons.alarm_rounded,
                                  accentColor: _AivyStatusColors.remindersStart,
                                  child: _RemindersSectionsAccordion(
                                    sections: reminderSections,
                                    selectedIds: _selectedIds,
                                    onToggleSelected: _toggleSelected,
                                    onSelectAllInView: _selectAllInList,
                                  ),
                                ),
                              );
                            }

                            final rightColumn = <Widget>[];

                            final weekPayEntries =
                                _buildWeekPaymentFollowUpEntries(payF, now);
                            rightColumn.add(
                              _ThisWeekPaymentFollowUpSection(
                                entries: weekPayEntries,
                                hasAnyOpenGroupedPayments: groupsRaw.isNotEmpty,
                                selectedIds: _selectedIds,
                                onToggleSelected: _toggleSelected,
                                onSelectAllInView: _selectAllInList,
                              ),
                            );
                            rightColumn.add(const SizedBox(height: 12));
                            if (payF.isNotEmpty) {
                              rightColumn.add(
                                _PendingByClientSection(
                                  groups: payF,
                                  dateFormat: _dateFormat,
                                  selectedIds: _selectedIds,
                                  onToggleSelected: _toggleSelected,
                                  onSelectAllInView: _selectAllInList,
                                ),
                              );
                              rightColumn.add(const SizedBox(height: 12));
                            }

                            rightColumn.add(
                              _RecentQuotationsSection(
                                quotations: quotesF,
                                dateFormat: _dateFormat,
                                selectedIds: _selectedIds,
                                onToggleSelected: _toggleSelected,
                                onSelectAllInView: _selectAllInList,
                              ),
                            );
                            rightColumn.add(const SizedBox(height: 12));

                            final ledgerFooter = ledgerF.isNotEmpty
                                ? Padding(
                                    padding: const EdgeInsets.only(top: 20),
                                    child: _LedgerFromChatAccordion(
                                      rows: ledgerF,
                                      dateFormat: _dateFormat,
                                      selectedIds: _selectedIds,
                                      onToggleSelected: _toggleSelected,
                                      onSelectAllInView: _selectAllInList,
                                    ),
                                  )
                                : const SizedBox.shrink();

                            if (hasAppLevelWork) {
                              rightColumn.add(
                                _ReportsSectionCard(
                                  title: 'All tasks by priority',
                                  subtitle: prioritized.isEmpty
                                      ? 'Nothing in the queue.'
                                      : 'Sorted smartest-first.',
                                  icon: Icons.insights_rounded,
                                  accentColor: _AivyStatusColors.focusStart,
                                  child: _TaskTable(
                                    items: prioritized,
                                    emptyText:
                                        'No tasks yet. Capture one in chat.',
                                    dateFormat: _dateFormat,
                                    selectedIds: _selectedIds,
                                    onToggleSelected: _toggleSelected,
                                    onSelectAllInView: _selectAllInList,
                                  ),
                                ),
                              );
                            }

                            const bottomPad = 96.0;
                            final bottomInset =
                                MediaQuery.paddingOf(context).bottom;
                            const horizontalPad = 16.0;

                            return LayoutBuilder(
                              builder: (context, constraints) {
                                final wide = constraints.maxWidth >=
                                    _kReportsWideBreakpoint;
                                final maxContent = math.min(
                                  constraints.maxWidth,
                                  _kReportsMaxContentWidth,
                                );
                                final selectionBarPad =
                                    _selectedIds.isNotEmpty ? 88.0 : 0.0;

                                final sectionsColumn = wide
                                    ? Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          IntrinsicHeight(
                                            child: Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Expanded(
                                                  flex: 5,
                                                  child: Column(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .stretch,
                                                    children: leftColumn,
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  flex: 6,
                                                  child: Column(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .stretch,
                                                    children: rightColumn,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          ledgerFooter,
                                        ],
                                      )
                                    : Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          ...leftColumn,
                                          ...rightColumn,
                                          ledgerFooter,
                                        ],
                                      );

                                return Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Positioned.fill(
                                      child: SingleChildScrollView(
                                        physics:
                                            const AlwaysScrollableScrollPhysics(),
                                        padding: EdgeInsets.fromLTRB(
                                          horizontalPad,
                                          4,
                                          horizontalPad,
                                          bottomPad +
                                              bottomInset +
                                              selectionBarPad,
                                        ),
                                        child: Align(
                                          alignment: Alignment.topCenter,
                                          child: ConstrainedBox(
                                            constraints: BoxConstraints(
                                              maxWidth: maxContent,
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                _ReportsToolbar(
                                                  searchController:
                                                      _searchController,
                                                  categoryFilter:
                                                      _categoryFilter,
                                                  onCategoryChanged:
                                                      _handleCategoryChanged,
                                                  taskCategoryCounts:
                                                      taskCategoryCounts,
                                                  filteredTaskCount:
                                                      tasks.length,
                                                  pendingReminderCount:
                                                      pendingReminders.length,
                                                  ledgerKindFilter:
                                                      _ledgerKindFilter,
                                                  onLedgerKindChanged: (v) =>
                                                      setState(() =>
                                                          _ledgerKindFilter =
                                                              v),
                                                  reminderScope:
                                                      _reminderScope,
                                                  onReminderScopeChanged: (v) =>
                                                      setState(() =>
                                                          _reminderScope = v),
                                                ),
                                                sectionsColumn,
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (_selectedIds.isNotEmpty)
                                      Positioned(
                                        left: 0,
                                        right: 0,
                                        bottom: 0,
                                        child: _ReportsSelectionBar(
                                          count: _selectedIds.length,
                                          onClear: _clearSelection,
                                        ),
                                      ),
                                  ],
                                );
                              },
                            );
                          },
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class _ReportsToolbar extends StatelessWidget {
  const _ReportsToolbar({
    required this.searchController,
    required this.categoryFilter,
    required this.onCategoryChanged,
    required this.taskCategoryCounts,
    required this.filteredTaskCount,
    required this.pendingReminderCount,
    required this.ledgerKindFilter,
    required this.onLedgerKindChanged,
    required this.reminderScope,
    required this.onReminderScopeChanged,
  });

  final TextEditingController searchController;
  final String categoryFilter;
  final ValueChanged<String> onCategoryChanged;
  final Map<String, int> taskCategoryCounts;
  final int filteredTaskCount;
  final int pendingReminderCount;
  final String ledgerKindFilter;
  final ValueChanged<String> onLedgerKindChanged;
  final String reminderScope;
  final ValueChanged<String> onReminderScopeChanged;

  static const _ledgerOptions = <({String id, String label})>[
    (id: 'all', label: 'Ledger: All'),
    (id: 'reminders', label: 'Reminders'),
    (id: 'payments', label: 'Payments'),
    (id: 'followups', label: 'Follow-ups'),
    (id: 'other', label: 'Other'),
  ];

  static const _scopeOptions = <({String id, String label})>[
    (id: 'all', label: 'Reminders: All'),
    (id: 'overdue', label: 'Overdue'),
    (id: 'today', label: 'Today'),
    (id: 'upcoming', label: 'Upcoming'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 0,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Align(
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: _kReportsMaxContentWidth,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: searchController,
                        decoration: InputDecoration(
                          hintText: 'Search tasks, reminders, ledger…',
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 22,
                          ),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Tasks (saved in Tasks)',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: ReportsTokens.muted(context),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                _CategoryFilterRow(
                  selected: categoryFilter,
                  onChanged: onCategoryChanged,
                  counts: taskCategoryCounts,
                ),
                const SizedBox(height: 6),
                Text(
                  categoryFilter == 'all'
                      ? 'Tasks: ${taskCategoryCounts['all'] ?? 0} · '
                            'Pending reminders: $pendingReminderCount '
                            "(Today's Focus = tasks + reminders)"
                      : 'Showing ${_CategoryFilterRow.labelOf(categoryFilter)} tasks ($filteredTaskCount)',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: ReportsTokens.muted(context),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Saved rows & reminder view',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: ReportsTokens.muted(context),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final o in _ledgerOptions)
                      FilterChip(
                        label: Text(o.label),
                        selected: ledgerKindFilter == o.id,
                        onSelected: (_) => onLedgerKindChanged(o.id),
                      ),
                    for (final o in _scopeOptions)
                      FilterChip(
                        label: Text(o.label),
                        selected: reminderScope == o.id,
                        onSelected: (_) => onReminderScopeChanged(o.id),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom bar when rows are selected. Export / Mark done are placeholders
/// until [ChatRepository] exposes bulk actions.
class _ReportsSelectionBar extends StatelessWidget {
  const _ReportsSelectionBar({required this.count, required this.onClear});

  final int count;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 10,
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Text(
                '$count selected',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              TextButton(onPressed: onClear, child: const Text('Clear')),
              Tooltip(
                message: 'TODO: wire export pipeline',
                child: FilledButton.tonal(
                  onPressed: null,
                  child: const Text('Export'),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message:
                    'TODO: wire ChatRepository bulk complete / task updates',
                child: FilledButton(
                  onPressed: null,
                  child: const Text('Mark done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef _SelectAllCallback = void Function(Iterable<String> ids, bool select);

class _TaskTable extends StatelessWidget {
  const _TaskTable({
    required this.items,
    required this.emptyText,
    required this.dateFormat,
    required this.selectedIds,
    required this.onToggleSelected,
    required this.onSelectAllInView,
  });

  final List<TaskItem> items;
  final String emptyText;
  final DateFormat dateFormat;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggleSelected;
  final _SelectAllCallback onSelectAllInView;

  static const int _maxRows = 48;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = ReportsTokens.muted(context);
    if (items.isEmpty) {
      return _SoftEmptyState(message: emptyText);
    }
    final visible = items.take(_maxRows).toList(growable: false);
    final ids = visible.map((t) => 'task:${t.id}').toList(growable: false);
    final allSelected = ids.isNotEmpty && ids.every(selectedIds.contains);
    final someSelected = ids.any(selectedIds.contains);

    Widget headerCell(String label, {int flex = 1}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: muted,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 520),
        child: Table(
          columnWidths: const {
            0: FixedColumnWidth(44),
            1: FlexColumnWidth(2.4),
            2: FlexColumnWidth(1.1),
            3: FlexColumnWidth(0.9),
          },
          border: TableBorder(
            horizontalInside: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.35),
            ),
          ),
          children: [
            TableRow(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.65,
                ),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Checkbox(
                    value: allSelected ? true : (someSelected ? null : false),
                    tristate: true,
                    onChanged: (v) {
                      if (v == null) {
                        onSelectAllInView(ids, false);
                      } else {
                        onSelectAllInView(ids, v);
                      }
                    },
                  ),
                ),
                headerCell('Task'),
                headerCell('Due'),
                headerCell('Category'),
              ],
            ),
            for (final task in visible)
              TableRow(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Checkbox(
                      value: selectedIds.contains('task:${task.id}'),
                      onChanged: (_) => onToggleSelected('task:${task.id}'),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 6,
                    ),
                    child: Text(
                      task.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 6,
                    ),
                    child: Text(
                      task.dueDateMs == null
                          ? '—'
                          : dateFormat.format(
                              DateTime.fromMillisecondsSinceEpoch(
                                task.dueDateMs!,
                              ),
                            ),
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 6,
                    ),
                    child: Text(
                      task.category,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _RemindersSectionsAccordion extends StatelessWidget {
  const _RemindersSectionsAccordion({
    required this.sections,
    required this.selectedIds,
    required this.onToggleSelected,
    required this.onSelectAllInView,
  });

  final List<ReminderReportSection> sections;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggleSelected;
  final _SelectAllCallback onSelectAllInView;

  @override
  Widget build(BuildContext context) {
    if (sections.isEmpty) {
      return _SoftEmptyState(
        message: 'No reminders in this view. Adjust filters or scope.',
      );
    }
    final theme = Theme.of(context);
    final muted = ReportsTokens.muted(context);

    final allIds = <String>[
      for (final s in sections)
        for (final r in s.items) 'rem:${r.id}',
    ];
    final headerSelected =
        allIds.isNotEmpty && allIds.every(selectedIds.contains);

    Widget rowForReminder(ReminderItem r) {
      final id = 'rem:${r.id}';
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: selectedIds.contains(id),
              onChanged: (_) => onToggleSelected(id),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(r.iconEmoji, style: const TextStyle(fontSize: 16)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    buildDisplayTitle(r),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${formatReminderReportDate(r)} · ${formatReminderReportTime(r)}',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                  if (reminderReportShowsPriorityLine(r))
                    Text(
                      r.priority,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (allIds.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                onSelectAllInView(allIds, !headerSelected);
              },
              icon: const Icon(Icons.select_all_rounded, size: 18),
              label: Text(
                headerSelected
                    ? 'Clear reminder selection'
                    : 'Select all visible',
              ),
            ),
          ),
        for (var i = 0; i < sections.length; i++) ...[
          if (i != 0)
            Divider(
              height: 1,
              color: theme.dividerColor.withValues(alpha: 0.25),
            ),
          Material(
            color: Colors.transparent,
            child: ExpansionTile(
              key: ValueKey<String>('rem-sec:${sections[i].sectionId}'),
              initiallyExpanded: sections[i].initiallyExpanded,
              tilePadding: const EdgeInsets.symmetric(horizontal: 4),
              collapsedShape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
              title: Text(
                sections[i].title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.primary,
                ),
              ),
              subtitle: Text(
                '${sections[i].items.length} '
                '${sections[i].items.length == 1 ? 'reminder' : 'reminders'}',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              childrenPadding: EdgeInsets.zero,
              children: [for (final r in sections[i].items) rowForReminder(r)],
            ),
          ),
        ],
      ],
    );
  }
}

class _SoftEmptyState extends StatelessWidget {
  const _SoftEmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.inbox_outlined,
            color: ReportsTokens.muted(context),
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: ReportsTokens.muted(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderPipelineSection extends StatelessWidget {
  const _OrderPipelineSection({
    required this.orders,
    required this.selectedIds,
    required this.onToggleSelected,
    required this.onSelectAllInView,
  });

  final List<OrderRecord> orders;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggleSelected;
  final _SelectAllCallback onSelectAllInView;

  @override
  Widget build(BuildContext context) {
    final pending = orders.where((o) => o.isPending).toList(growable: false);
    final dispatched = orders.where((o) => o.isDispatched).length;
    final stages = <String, int>{
      'plate_received': 0,
      'printing_done': 0,
      'punching_done': 0,
      'material_ready': 0,
    };
    for (final o in pending) {
      final key = (o.processStage ?? '').trim().toLowerCase();
      if (stages.containsKey(key)) {
        stages[key] = (stages[key] ?? 0) + 1;
      }
    }
    final cur = NumberFormat.currency(
      locale: 'en_IN',
      symbol: '₹',
      decimalDigits: 0,
    );
    final theme = Theme.of(context);
    final show = pending.take(12).toList(growable: false);
    final ids = show.map((o) => 'order:${o.id}').toList(growable: false);
    final allSel = ids.isNotEmpty && ids.every(selectedIds.contains);
    final someSel = ids.any(selectedIds.contains);

    return _ReportsSectionCard(
      title: 'Order pipeline',
      subtitle:
          'Pending ${pending.length} · Dispatched $dispatched · Stage-wise live snapshot',
      icon: Icons.factory_rounded,
      accentColor: ReportsTokens.accentPrimary(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _PillBadge(
                label: 'Plate ${stages['plate_received']}',
                bg: const Color(0xFFE0F2FE),
                fg: const Color(0xFF0369A1),
              ),
              _PillBadge(
                label: 'Printing ${stages['printing_done']}',
                bg: const Color(0xFFEDE9FE),
                fg: const Color(0xFF5B21B6),
              ),
              _PillBadge(
                label: 'Punching ${stages['punching_done']}',
                bg: const Color(0xFFFEE2E2),
                fg: const Color(0xFFB91C1C),
              ),
              _PillBadge(
                label: 'Material ${stages['material_ready']}',
                bg: const Color(0xFFDCFCE7),
                fg: const Color(0xFF166534),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 480),
              child: Table(
                columnWidths: const {
                  0: FixedColumnWidth(44),
                  1: FlexColumnWidth(1.6),
                  2: FlexColumnWidth(0.9),
                  3: FlexColumnWidth(1),
                },
                border: TableBorder(
                  horizontalInside: BorderSide(
                    color: theme.dividerColor.withValues(alpha: 0.35),
                  ),
                ),
                children: [
                  TableRow(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.65),
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Checkbox(
                          value: allSel ? true : (someSel ? null : false),
                          tristate: true,
                          onChanged: (v) {
                            if (v == null) {
                              onSelectAllInView(ids, false);
                            } else {
                              onSelectAllInView(ids, v);
                            }
                          },
                        ),
                      ),
                      _tableHead(context, 'Client'),
                      _tableHead(context, 'Amount'),
                      _tableHead(context, 'Stage'),
                    ],
                  ),
                  for (final o in show)
                    TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Checkbox(
                            value: selectedIds.contains('order:${o.id}'),
                            onChanged: (_) => onToggleSelected('order:${o.id}'),
                          ),
                        ),
                        _tableCell(
                          context,
                          o.clientName?.trim().isNotEmpty == true
                              ? o.clientName!.trim()
                              : '—',
                        ),
                        _tableCell(context, cur.format(o.amount)),
                        _tableCell(
                          context,
                          _OrderPipelineSection._stageLabel(o.processStage),
                          muted: true,
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _tableHead(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: ReportsTokens.muted(context),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  static Widget _tableCell(
    BuildContext context,
    String text, {
    bool muted = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: muted ? ReportsTokens.muted(context) : null,
        ),
      ),
    );
  }

  static String _stageLabel(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'plate_received':
        return 'Plate received';
      case 'printing_done':
        return 'Printing done';
      case 'punching_done':
        return 'Punching done';
      case 'material_ready':
        return 'Material ready';
      default:
        return 'No stage';
    }
  }
}

class _WeekPaymentFollowUpEntry {
  const _WeekPaymentFollowUpEntry({
    required this.payment,
    required this.clientName,
    required this.whenDetail,
    required this.sortDaysLate,
    required this.displayAmount,
  });

  final PaymentRecord payment;
  final String clientName;
  final String whenDetail;
  final int sortDaysLate;
  final double displayAmount;
}

/// This week's payment chase list — above **Highest pending** on Reports.
class _ThisWeekPaymentFollowUpSection extends StatelessWidget {
  const _ThisWeekPaymentFollowUpSection({
    required this.entries,
    required this.hasAnyOpenGroupedPayments,
    required this.selectedIds,
    required this.onToggleSelected,
    required this.onSelectAllInView,
  });

  final List<_WeekPaymentFollowUpEntry> entries;
  final bool hasAnyOpenGroupedPayments;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggleSelected;
  final _SelectAllCallback onSelectAllInView;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cur = NumberFormat.currency(
      locale: 'en_IN',
      symbol: '₹',
      decimalDigits: 0,
    );
    final visible = entries.take(40).toList(growable: false);

    return _ReportsSectionCard(
      title: 'This week · payment follow-up',
      subtitle:
          'Yahan overdue, is calendar week ki due, aur agle ~30 din tak ki open '
          'due dikhti hai delay / countdown ke saath. Neeche "Highest pending" '
          'me aur bhi lamba backlog ho sakta hai.',
      icon: Icons.event_note_rounded,
      accentColor: ReportsTokens.accentPrimary(context),
      child: visible.isEmpty
          ? _SoftEmptyState(
              message: hasAnyOpenGroupedPayments
                  ? 'Is filter ke andar abhi line match nahi hui '
                        '(search bar check karo). Jab koi overdue / near-term '
                        'due milegi to yahan list banegi.'
                  : 'Abhi report me koi grouped open payment row nahi mili '
                        '(search bar check karo).',
            )
          : _WeekFollowUpTableBody(
              visible: visible,
              cur: cur,
              theme: theme,
              selectedIds: selectedIds,
              onToggleSelected: onToggleSelected,
              onSelectAllInView: onSelectAllInView,
            ),
    );
  }
}

class _WeekFollowUpTableBody extends StatelessWidget {
  const _WeekFollowUpTableBody({
    required this.visible,
    required this.cur,
    required this.theme,
    required this.selectedIds,
    required this.onToggleSelected,
    required this.onSelectAllInView,
  });

  final List<_WeekPaymentFollowUpEntry> visible;
  final NumberFormat cur;
  final ThemeData theme;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggleSelected;
  final _SelectAllCallback onSelectAllInView;

  @override
  Widget build(BuildContext context) {
    final ids = visible
        .map((e) => 'pay:${e.payment.id}')
        .toList(growable: false);
    final allSel = ids.isNotEmpty && ids.every(selectedIds.contains);
    final someSel = ids.any(selectedIds.contains);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 520),
        child: Table(
          columnWidths: const {
            0: FixedColumnWidth(44),
            1: FlexColumnWidth(1.05),
            2: FlexColumnWidth(2.1),
            3: FlexColumnWidth(0.82),
          },
          border: TableBorder(
            horizontalInside: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.35),
            ),
          ),
          children: [
            TableRow(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.65,
                ),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Checkbox(
                    value: allSel ? true : (someSel ? null : false),
                    tristate: true,
                    onChanged: (v) {
                      if (v == null) {
                        onSelectAllInView(ids, false);
                      } else {
                        onSelectAllInView(ids, v);
                      }
                    },
                  ),
                ),
                _PendingByClientSection._h(context, 'Client'),
                _PendingByClientSection._h(context, 'Due & follow-up'),
                _PendingByClientSection._h(context, 'Outstanding'),
              ],
            ),
            for (var i = 0; i < visible.length; i++)
              TableRow(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Checkbox(
                      value: selectedIds.contains(
                        'pay:${visible[i].payment.id}',
                      ),
                      onChanged: (_) =>
                          onToggleSelected('pay:${visible[i].payment.id}'),
                    ),
                  ),
                  _PendingByClientSection._c(context, visible[i].clientName),
                  _PendingByClientSection._c(
                    context,
                    '${i + 1}. ${visible[i].whenDetail}',
                    small: true,
                  ),
                  _PendingByClientSection._c(
                    context,
                    visible[i].displayAmount > 0
                        ? cur.format(visible[i].displayAmount)
                        : '—',
                    emphasis: visible[i].sortDaysLate > 0,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _RecentQuotationsSection extends StatelessWidget {
  const _RecentQuotationsSection({
    required this.quotations,
    required this.dateFormat,
    required this.selectedIds,
    required this.onToggleSelected,
    required this.onSelectAllInView,
  });

  final List<QuotationRecord> quotations;
  final DateFormat dateFormat;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggleSelected;
  final _SelectAllCallback onSelectAllInView;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cur = NumberFormat.currency(
      locale: 'en_IN',
      symbol: '₹',
      decimalDigits: 0,
    );
    final visible = quotations.take(50).toList(growable: false);
    final ids = visible.map((q) => 'quote:${q.id}').toList(growable: false);
    final allSel = ids.isNotEmpty && ids.every(selectedIds.contains);
    final someSel = ids.any(selectedIds.contains);

    return _ReportsSectionCard(
      title: 'Quotations sent (last 10 days)',
      subtitle:
          'Jo quotations chat / quotation flow se save hue — client, bhejne ki '
          'date, rakam. Search se client naam filter.',
      icon: Icons.request_quote_rounded,
      accentColor: ReportsTokens.accentSecondary(context),
      child: visible.isEmpty
          ? const _SoftEmptyState(
              message:
                  'Pichle 10 din me koi quotation save nahi mila. Chat se '
                  'Quotation flow use karke save karo.',
            )
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 480),
                child: Table(
                  columnWidths: const {
                    0: FixedColumnWidth(44),
                    1: FlexColumnWidth(1.2),
                    2: FlexColumnWidth(1.3),
                    3: FlexColumnWidth(0.85),
                  },
                  border: TableBorder(
                    horizontalInside: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.35),
                    ),
                  ),
                  children: [
                    TableRow(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.65),
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Checkbox(
                            value: allSel ? true : (someSel ? null : false),
                            tristate: true,
                            onChanged: (v) {
                              if (v == null) {
                                onSelectAllInView(ids, false);
                              } else {
                                onSelectAllInView(ids, v);
                              }
                            },
                          ),
                        ),
                        _PendingByClientSection._h(context, 'Client'),
                        _PendingByClientSection._h(context, 'Sent on'),
                        _PendingByClientSection._h(context, 'Amount'),
                      ],
                    ),
                    for (var i = 0; i < visible.length; i++)
                      TableRow(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Checkbox(
                              value: selectedIds.contains(
                                'quote:${visible[i].id}',
                              ),
                              onChanged: (_) =>
                                  onToggleSelected('quote:${visible[i].id}'),
                            ),
                          ),
                          _PendingByClientSection._c(
                            context,
                            (visible[i].clientName ?? '').trim().isEmpty
                                ? '—'
                                : visible[i].clientName!.trim(),
                          ),
                          _PendingByClientSection._c(
                            context,
                            visible[i].createdAtMs > 0
                                ? dateFormat.format(
                                    DateTime.fromMillisecondsSinceEpoch(
                                      visible[i].createdAtMs,
                                      isUtc: false,
                                    ),
                                  )
                                : '—',
                          ),
                          _PendingByClientSection._c(
                            context,
                            visible[i].amount > 0
                                ? cur.format(visible[i].amount)
                                : '—',
                            emphasis: true,
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// Pending dues summed per client (Firestore `payments`), sorted high → low.
class _PendingByClientSection extends StatelessWidget {
  const _PendingByClientSection({
    required this.groups,
    required this.dateFormat,
    required this.selectedIds,
    required this.onToggleSelected,
    required this.onSelectAllInView,
  });

  final List<ClientPendingDuesSummary> groups;
  final DateFormat dateFormat;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggleSelected;
  final _SelectAllCallback onSelectAllInView;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = groups.take(12).toList();
    final cur = NumberFormat.currency(
      locale: 'en_IN',
      symbol: '₹',
      decimalDigits: 0,
    );
    final payRows = <({PaymentRecord p, String clientName})>[];
    for (final g in top) {
      for (final p in g.dues) {
        payRows.add((p: p, clientName: g.clientName));
      }
    }
    final visible = payRows.take(36).toList(growable: false);
    final ids = visible.map((e) => 'pay:${e.p.id}').toList(growable: false);
    final allSel = ids.isNotEmpty && ids.every(selectedIds.contains);
    final someSel = ids.any(selectedIds.contains);

    return _ReportsSectionCard(
      title: 'Highest pending (by client)',
      subtitle:
          'Pending + overdue payment_due rows, grouped and summed. Read-only.',
      icon: Icons.account_balance_wallet_outlined,
      accentColor: ReportsTokens.overdue(context),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 520),
          child: Table(
            columnWidths: const {
              0: FixedColumnWidth(44),
              1: FlexColumnWidth(1.1),
              2: FlexColumnWidth(2),
              3: FlexColumnWidth(0.85),
            },
            border: TableBorder(
              horizontalInside: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.35),
              ),
            ),
            children: [
              TableRow(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.65,
                  ),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Checkbox(
                      value: allSel ? true : (someSel ? null : false),
                      tristate: true,
                      onChanged: (v) {
                        if (v == null) {
                          onSelectAllInView(ids, false);
                        } else {
                          onSelectAllInView(ids, v);
                        }
                      },
                    ),
                  ),
                  _PendingByClientSection._h(context, 'Client'),
                  _PendingByClientSection._h(context, 'Detail'),
                  _PendingByClientSection._h(context, 'Amount'),
                ],
              ),
              for (var i = 0; i < visible.length; i++)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Checkbox(
                        value: selectedIds.contains('pay:${visible[i].p.id}'),
                        onChanged: (_) =>
                            onToggleSelected('pay:${visible[i].p.id}'),
                      ),
                    ),
                    _PendingByClientSection._c(context, visible[i].clientName),
                    _PendingByClientSection._c(
                      context,
                      _PendingByClientSection._line(
                        i + 1,
                        visible[i].p,
                        dateFormat,
                        cur,
                      ),
                    ),
                    _PendingByClientSection._c(
                      context,
                      _PendingByClientSection._amountCell(visible[i].p, cur),
                      emphasis: true,
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _h(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: ReportsTokens.muted(context),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  static Widget _c(
    BuildContext context,
    String text, {
    bool small = false,
    bool emphasis = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style:
            (small
                    ? Theme.of(context).textTheme.bodySmall
                    : Theme.of(context).textTheme.bodyMedium)
                ?.copyWith(
                  fontWeight: emphasis ? FontWeight.w700 : null,
                  color: emphasis ? ReportsTokens.overdue(context) : null,
                ),
      ),
    );
  }

  static String _amountCell(PaymentRecord p, NumberFormat cur) {
    final display = p.effectiveRemaining > 0
        ? p.effectiveRemaining
        : (p.amount ?? 0);
    return display > 0 ? cur.format(display) : '—';
  }

  static String _line(int n, PaymentRecord p, DateFormat df, NumberFormat cur) {
    final st = p.status.toLowerCase();
    final stLabel = switch (st) {
      'overdue' => 'Overdue',
      'partial_pending' => 'Partial pending',
      _ => 'Pending',
    };
    final ms = p.dueDateMs;
    final dueBit = ms != null && ms > 0
        ? df.format(DateTime.fromMillisecondsSinceEpoch(ms, isUtc: false))
        : '—';
    final display = p.effectiveRemaining > 0
        ? p.effectiveRemaining
        : (p.amount ?? 0);
    final amt = display > 0 ? cur.format(display) : '—';
    return '$n. $amt – Due $dueBit ($stLabel)';
  }
}

/// Summarised trail of what Aivy saved during chat: payment lines, reminders,
/// follow‑ups, and other ledger notes—same data as before, without technical labels.
class _LedgerFromChatAccordion extends StatelessWidget {
  const _LedgerFromChatAccordion({
    required this.rows,
    required this.dateFormat,
    required this.selectedIds,
    required this.onToggleSelected,
    required this.onSelectAllInView,
  });

  final List<Map<String, dynamic>> rows;
  final DateFormat dateFormat;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggleSelected;
  final _SelectAllCallback onSelectAllInView;

  static int _pendingPaymentCount(List<Map<String, dynamic>> rows) {
    return rows.where((r) {
      final op = (r['lastActionType'] as String? ?? '').trim();
      final st = (r['status'] as String? ?? '').toLowerCase();
      if (op != 'payment_due_created') {
        return false;
      }
      return st == 'pending' || st == 'overdue' || st == 'partial_pending';
    }).length;
  }

  static int _followUpCount(List<Map<String, dynamic>> rows) {
    return rows.where((r) {
      final t = (r['type'] as String? ?? '').toLowerCase();
      return t == 'followup';
    }).length;
  }

  static String _summaryLine(List<Map<String, dynamic>> rows) {
    final total = rows.length;
    final pend = _pendingPaymentCount(rows);
    final fus = _followUpCount(rows);
    final parts = <String>[
      '$total ${total == 1 ? 'saved line' : 'saved lines'}',
      if (pend > 0) '$pend payment${pend == 1 ? '' : 's'} to track',
      if (fus > 0) '$fus follow‑up${fus == 1 ? '' : 's'}',
    ];
    return '${parts.join(' · ')} · tap to expand';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = ReportsTokens.accentSecondary(context);

    final show = rows;
    final ids = <String>[
      for (var i = 0; i < show.length; i++) _ledgerRowId(show[i], i),
    ];
    final allSel = ids.isNotEmpty && ids.every(selectedIds.contains);
    final someSel = ids.any(selectedIds.contains);

    return _PremiumCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        initiallyExpanded: false,
        collapsedIconColor: accent,
        iconColor: accent,
        tilePadding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: ReportsTokens.tintHeader(context, accent),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.forum_rounded, color: accent, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Working notes from chat',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    _summaryLine(rows),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: ReportsTokens.muted(context),
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        expandedAlignment: Alignment.topCenter,
        childrenPadding: const EdgeInsets.only(
          left: 8,
          right: 8,
          bottom: 12,
          top: 2,
        ),
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 520),
              child: Table(
                columnWidths: const {
                  0: FixedColumnWidth(44),
                  1: FlexColumnWidth(0.75),
                  2: FlexColumnWidth(1.5),
                  3: FlexColumnWidth(1.2),
                },
                border: TableBorder(
                  horizontalInside: BorderSide(
                    color: theme.dividerColor.withValues(alpha: 0.35),
                  ),
                ),
                children: [
                  TableRow(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.65),
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Checkbox(
                          value: allSel ? true : (someSel ? null : false),
                          tristate: true,
                          onChanged: (v) {
                            if (v == null) {
                              onSelectAllInView(ids, false);
                            } else {
                              onSelectAllInView(ids, v);
                            }
                          },
                        ),
                      ),
                      _ledgerTh(context, 'Type'),
                      _ledgerTh(context, 'Title'),
                      _ledgerTh(context, 'When'),
                    ],
                  ),
                  for (var i = 0; i < show.length; i++)
                    TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Checkbox(
                            value: selectedIds.contains(
                              _ledgerRowId(show[i], i),
                            ),
                            onChanged: (_) =>
                                onToggleSelected(_ledgerRowId(show[i], i)),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 6,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.secondaryContainer
                                  .withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _ledgerBadgeFor(show[i]),
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 6,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                [
                                      (show[i]['clientName'] as String? ?? '')
                                          .trim(),
                                      if (show[i]['amount'] != null)
                                        '₹${(show[i]['amount'] as num).toStringAsFixed(0)}',
                                    ]
                                    .where(
                                      (s) => s.toString().trim().isNotEmpty,
                                    )
                                    .join(' · '),
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if ((show[i]['note'] as String? ?? '')
                                  .trim()
                                  .isNotEmpty)
                                Text(
                                  (show[i]['note'] as String).trim(),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: ReportsTokens.muted(context),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 6,
                          ),
                          child: Text(
                            _timestampLine(show[i], dateFormat),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: ReportsTokens.muted(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _ledgerTh(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: ReportsTokens.muted(context),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  static String _timestampLine(Map<String, dynamic> r, DateFormat df) {
    final ms = (r['createdAtMs'] as num?)?.toInt();
    if (ms != null && ms > 0) {
      return df.format(DateTime.fromMillisecondsSinceEpoch(ms, isUtc: false));
    }
    final savedId = (r['savedDocId'] as String? ?? '').trim();
    if (savedId.isNotEmpty) {
      return 'Ref $savedId';
    }
    return '';
  }
}

// -- Section shell (muted, theme-aligned) -----------------------------------

class _ReportsSectionCard extends StatelessWidget {
  const _ReportsSectionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    required this.child,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accentColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _PremiumCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(
              color: ReportsTokens.tintHeader(context, accentColor),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
              border: Border(
                bottom: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 4,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 12),
                Icon(icon, color: accentColor, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: ReportsTokens.muted(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
            child: child,
          ),
        ],
      ),
    );
  }
}

// -- Today's Focus (automatic timeline) ------------------------------------

class _TodaysFocusTimelineCard extends StatelessWidget {
  const _TodaysFocusTimelineCard({
    required this.items,
    required this.completingIds,
    required this.onMarkDone,
  });

  final List<_TodayFocusItem> items;
  final Set<String> completingIds;
  final ValueChanged<_TodayFocusItem> onMarkDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final overdueCount = items.where((item) => item.isOverdue).length;
    return _ReportsSectionCard(
      title: "Today's Focus",
      subtitle: items.isEmpty
          ? 'No calls, meetings, follow-ups, or tasks due today.'
          : '${items.length} item${items.length == 1 ? '' : 's'} today'
                '${overdueCount > 0 ? ' · $overdueCount overdue' : ''}',
      icon: Icons.today_rounded,
      accentColor: overdueCount > 0
          ? ReportsTokens.overdue(context)
          : ReportsTokens.accentPrimary(context),
      child: items.isEmpty
          ? const _SoftEmptyState(
              message:
                  'Nothing scheduled for today. New calls, meetings, follow-ups, and tasks will appear here automatically.',
            )
          : Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      color: theme.dividerColor.withValues(alpha: 0.35),
                    ),
                  _TodayFocusTimelineRow(
                    item: items[i],
                    now: now,
                    isCompleting: completingIds.contains(items[i].id),
                    onMarkDone: () => onMarkDone(items[i]),
                  ),
                ],
              ],
            ),
    );
  }
}

class _TodayFocusTimelineRow extends StatelessWidget {
  const _TodayFocusTimelineRow({
    required this.item,
    required this.now,
    required this.isCompleting,
    required this.onMarkDone,
  });

  final _TodayFocusItem item;
  final DateTime now;
  final bool isCompleting;
  final VoidCallback onMarkDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final when = DateTime.fromMillisecondsSinceEpoch(item.whenMs);
    final accent = item.isOverdue
        ? ReportsTokens.overdue(context)
        : _accentForKind(context, item.kind);
    final soft = ReportsTokens.tintHeader(context, accent);
    final timeLabel = DateFormat('hh:mm a').format(when);
    final overdueBy = item.isOverdue ? _overdueLabel(now, when) : null;

    return Container(
      color: item.isOverdue
          ? ReportsTokens.overdueSoft(context).withValues(alpha: 0.35)
          : null,
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  timeLabel,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (overdueBy != null)
                  Text(
                    overdueBy,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: soft,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: accent.withValues(alpha: 0.2)),
            ),
            child: Icon(_iconForKind(item.kind), color: accent, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _PillBadge(
                      label: _labelForKind(item.kind),
                      bg: soft,
                      fg: accent,
                    ),
                    if (item.isOverdue)
                      _PillBadge(
                        label: 'Overdue',
                        bg: ReportsTokens.overdueSoft(context),
                        fg: ReportsTokens.overdue(context),
                      ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
                if (item.reason.trim().isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    item.reason,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: ReportsTokens.muted(context),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: isCompleting ? null : onMarkDone,
            icon: isCompleting
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded, size: 17),
            label: const Text('Done'),
          ),
        ],
      ),
    );
  }

  static IconData _iconForKind(_TodayFocusKind kind) {
    switch (kind) {
      case _TodayFocusKind.call:
        return Icons.call_rounded;
      case _TodayFocusKind.meeting:
        return Icons.groups_rounded;
      case _TodayFocusKind.followUp:
        return Icons.handshake_rounded;
      case _TodayFocusKind.task:
        return Icons.check_circle_outline_rounded;
    }
  }

  static String _labelForKind(_TodayFocusKind kind) {
    switch (kind) {
      case _TodayFocusKind.call:
        return 'Call';
      case _TodayFocusKind.meeting:
        return 'Meeting';
      case _TodayFocusKind.followUp:
        return 'Follow-up';
      case _TodayFocusKind.task:
        return 'Task';
    }
  }

  static Color _accentForKind(BuildContext context, _TodayFocusKind kind) {
    switch (kind) {
      case _TodayFocusKind.call:
        return _AivyStatusColors.remindersStart;
      case _TodayFocusKind.meeting:
        return ReportsTokens.accentPrimary(context);
      case _TodayFocusKind.followUp:
        return _AivyStatusColors.clientStart;
      case _TodayFocusKind.task:
        return _AivyStatusColors.dueToday;
    }
  }

  static String _overdueLabel(DateTime now, DateTime when) {
    final diff = now.difference(when);
    if (diff.inDays > 0) {
      return '${diff.inDays}d late';
    }
    if (diff.inHours > 0) {
      return '${diff.inHours}h late';
    }
    final mins = diff.inMinutes.clamp(1, 59);
    return '${mins}m late';
  }
}

// -- Category filter --------------------------------------------------------

/// Segmented chip row that controls which category of tasks the dashboard
/// sections show.
class _CategoryFilterRow extends StatelessWidget {
  const _CategoryFilterRow({
    required this.selected,
    required this.onChanged,
    required this.counts,
  });

  final String selected;
  final ValueChanged<String> onChanged;
  final Map<String, int> counts;

  static const List<({String id, String label, IconData icon})> _options = [
    (id: 'all', label: 'All', icon: Icons.inbox_outlined),
    (id: 'client', label: 'Client', icon: Icons.business_center_outlined),
    (id: 'work', label: 'Work', icon: Icons.work_outline),
    (id: 'personal', label: 'Personal', icon: Icons.person_outline),
    (id: 'general', label: 'General', icon: Icons.label_outline),
  ];

  static String labelOf(String id) {
    for (final option in _options) {
      if (option.id == id) {
        return option.label;
      }
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _options
          .map((option) {
            final isSelected = option.id == selected;
            final count = counts[option.id] ?? 0;
            return FilterChip(
              avatar: Icon(option.icon, size: 16),
              label: Text('${option.label} ($count)'),
              selected: isSelected,
              onSelected: (_) => onChanged(option.id),
            );
          })
          .toList(growable: false),
    );
  }
}

// -- Atoms ------------------------------------------------------------------

class _PremiumCard extends StatelessWidget {
  const _PremiumCard({required this.child, required this.padding});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F0F172A),
            blurRadius: 18,
            offset: Offset(0, 4),
          ),
        ],
      ),
      padding: padding,
      child: child,
    );
  }
}

class _PillBadge extends StatelessWidget {
  const _PillBadge({required this.label, required this.bg, required this.fg});

  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w700,
          fontSize: 11,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
