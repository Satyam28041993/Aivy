import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/design/aivy_ui.dart';
import '../../visits/models/visit_record.dart' show DsrSheet;
import '../data/expense_repository.dart';
import '../models/travel_expense.dart';

/// The travel claim on the phone: every day's kilometres, leg by leg, with the
/// Excel the company gets one tap away.
///
/// Days are cards by default — a day is a little route, and a card reads it in
/// order. The table view is the sheet's own shape, one row per leg.
class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key, required this.userId});

  final String userId;

  static Future<void> open(BuildContext context, {required String userId}) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ExpensesScreen(userId: userId)),
    );
  }

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

enum _Period { week, month, lastMonth, all }

class _ExpensesScreenState extends State<ExpensesScreen> {
  final ExpenseRepository _repo = ExpenseRepository();
  _Period _period = _Period.month;
  bool _table = false;

  late final Stream<List<TravelExpense>> _days = _repo.watchExpenses(widget.userId);
  late final Stream<DsrSheet?> _sheet = _repo.watchSheet(widget.userId);

  static const Map<_Period, String> _labels = {
    _Period.week: 'This week',
    _Period.month: 'This month',
    _Period.lastMonth: 'Last month',
    _Period.all: 'All',
  };

  bool _inPeriod(TravelExpense e) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = e.date;
    switch (_period) {
      case _Period.week:
        return !d.isBefore(today.subtract(Duration(days: today.weekday - 1)));
      case _Period.month:
        return !d.isBefore(DateTime(now.year, now.month));
      case _Period.lastMonth:
        return !d.isBefore(DateTime(now.year, now.month - 1)) &&
            d.isBefore(DateTime(now.year, now.month));
      case _Period.all:
        return true;
    }
  }

  Future<void> _open(String url) async {
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open it. Try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AivyUi.bg,
      appBar: AppBar(
        backgroundColor: AivyUi.bg,
        foregroundColor: AivyUi.ink,
        elevation: 0,
        title: Text('Travel expense', style: AivyUi.title(context).copyWith(fontSize: 19)),
      ),
      body: SafeArea(
        top: false,
        child: StreamBuilder<List<TravelExpense>>(
          stream: _days,
          builder: (context, snap) {
            final loading = !snap.hasData && !snap.hasError;
            final rows = (snap.data ?? const <TravelExpense>[]).where(_inPeriod).toList();
            final km = rows.fold<double>(0, (a, e) => a + e.totalKm);
            final amount = rows.fold<double>(0, (a, e) => a + e.totalAmount);
            return ListView(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 28),
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final e in _labels.entries) ...[
                        ChoiceChip(
                          label: Text(e.value),
                          selected: _period == e.key,
                          onSelected: (_) => setState(() => _period = e.key),
                          selectedColor: AivyUi.brand.withValues(alpha: 0.18),
                          backgroundColor: AivyUi.surface,
                          side: BorderSide(color: _period == e.key ? AivyUi.brand : AivyUi.line),
                          labelStyle: AivyUi.soft(context).copyWith(
                            color: _period == e.key ? AivyUi.brand : AivyUi.inkSoft,
                          ),
                          showCheckmark: false,
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(child: _Tile(label: 'Days', value: '${rows.length}', color: AivyUi.brand)),
                    const SizedBox(width: 10),
                    Expanded(child: _Tile(label: 'Km', value: trimNum(km), color: AivyUi.info)),
                    const SizedBox(width: 10),
                    Expanded(child: _Tile(label: 'Claim', value: AivyUi.inrExact(amount), color: AivyUi.ok)),
                  ],
                ),
                const SizedBox(height: 14),
                StreamBuilder<DsrSheet?>(
                  stream: _sheet,
                  builder: (context, s) => _ExcelActions(sheet: s.data, onOpen: _open),
                ),
                const SizedBox(height: 18),
                AivySectionHeader(
                  title: _labels[_period]!,
                  count: rows.length,
                  action: _table ? 'Card view' : 'Table view',
                  onAction: () => setState(() => _table = !_table),
                ),
                if (snap.hasError)
                  const AivyCard(child: AivyEmpty('Could not load expenses.', icon: Icons.error_outline))
                else if (loading)
                  const AivyCard(
                    child: Center(
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  )
                else if (rows.isEmpty)
                  const AivyCard(
                    child: AivyEmpty(
                      'No travel here yet. On a day with visits Aivy asks at 8 PM — or say "expense entry karo".',
                      icon: Icons.two_wheeler_outlined,
                    ),
                  )
                else if (_table)
                  _LegTable(rows: rows)
                else
                  for (final e in rows) ...[
                    _DayCard(day: e),
                    const SizedBox(height: 10),
                  ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AivyCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: AivyUi.display(context).copyWith(fontSize: 24, color: color)),
          ),
          const SizedBox(height: 2),
          Text(label, style: AivyUi.soft(context), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

class _ExcelActions extends StatelessWidget {
  const _ExcelActions({required this.sheet, required this.onOpen});

  final DsrSheet? sheet;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final s = sheet;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(AivyUi.radiusSm));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: s == null ? null : () => onOpen(s.xlsxUrl),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Download Excel'),
                style: FilledButton.styleFrom(
                  backgroundColor: AivyUi.ok,
                  foregroundColor: AivyUi.bg,
                  disabledBackgroundColor: AivyUi.surfaceHigh,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: shape,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: s == null ? null : () => onOpen(s.openUrl),
                icon: const Icon(Icons.table_chart_outlined, size: 18),
                label: const Text('Open Sheet'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AivyUi.ink,
                  side: const BorderSide(color: AivyUi.line),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: shape,
                ),
              ),
            ),
          ],
        ),
        if (s == null)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: Text(
              'The Excel file is ready once your first day of travel is saved with Google allowed.',
              style: AivyUi.soft(context),
            ),
          ),
      ],
    );
  }
}

String _dateOf(TravelExpense e) =>
    e.dateLabel.isNotEmpty ? e.dateLabel : DateFormat('dd-MMM-yyyy').format(e.date);

/// One day: its total up top, then the route leg by leg.
class _DayCard extends StatelessWidget {
  const _DayCard({required this.day});

  final TravelExpense day;

  @override
  Widget build(BuildContext context) {
    final e = day;
    return AivyCard(
      accent: AivyUi.ok,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _dateOf(e),
                  style: AivyUi.body(context).copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                AivyUi.inrExact(e.totalAmount),
                style: AivyUi.body(context).copyWith(
                  fontWeight: FontWeight.w700,
                  color: AivyUi.ok,
                  fontFeatures: AivyUi.tabular,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              AivyPill('${trimNum(e.totalKm)} km', color: AivyUi.info),
              AivyPill('₹${trimNum(e.ratePerKm)}/km · ${e.vehicle}'),
              if (!e.inSheet) const AivyPill('Sheet pending', color: AivyUi.warn),
            ],
          ),
          const SizedBox(height: 10),
          for (final l in e.legs)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3, right: 8),
                    child: Icon(Icons.arrow_forward, size: 14, color: AivyUi.inkFaint),
                  ),
                  Expanded(
                    child: Text(
                      '${l.from} → ${l.to}',
                      style: AivyUi.soft(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${trimNum(l.km)} km',
                    style: AivyUi.soft(context).copyWith(fontFeatures: AivyUi.tabular),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The sheet's shape: one row per leg. Scrolls sideways on a phone.
class _LegTable extends StatelessWidget {
  const _LegTable({required this.rows});

  final List<TravelExpense> rows;

  static const List<String> _columns = ['Date', 'From', 'To', 'Purpose', 'Km', 'Rate', 'Amount'];

  @override
  Widget build(BuildContext context) {
    final cell = AivyUi.soft(context).copyWith(color: AivyUi.ink);
    Widget wide(String s, double w) => SizedBox(
          width: w,
          child: Text(s, style: cell, maxLines: 2, overflow: TextOverflow.ellipsis),
        );
    return AivyCard(
      padding: EdgeInsets.zero,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 40,
          dataRowMinHeight: 40,
          dataRowMaxHeight: 56,
          columnSpacing: 18,
          headingTextStyle: AivyUi.label(context),
          columns: [for (final c in _columns) DataColumn(label: Text(c.toUpperCase()))],
          rows: [
            for (final e in rows)
              for (final l in e.legs)
                DataRow(
                  cells: [
                    DataCell(Text(_dateOf(e), style: cell)),
                    DataCell(wide(l.from, 140)),
                    DataCell(wide(l.to, 140)),
                    DataCell(wide(l.purpose, 110)),
                    DataCell(Text(trimNum(l.km), style: cell)),
                    DataCell(Text(trimNum(e.ratePerKm), style: cell)),
                    DataCell(Text(trimNum(l.amount), style: cell)),
                  ],
                ),
          ],
        ),
      ),
    );
  }
}
