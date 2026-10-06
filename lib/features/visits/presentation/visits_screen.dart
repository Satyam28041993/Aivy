import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/design/aivy_ui.dart';
import '../data/visit_repository.dart';
import '../models/visit_record.dart';

/// The DSR on the phone: every client visit, as a table the user can read the
/// way they read the sheet, with the Excel download one tap away.
///
/// The table is the default because that is the shape the company sees; the
/// card view is there for a one-handed scroll on the road. Both read the same
/// stream, so they can never disagree.
class VisitsScreen extends StatefulWidget {
  const VisitsScreen({super.key, required this.userId});

  final String userId;

  static Future<void> open(BuildContext context, {required String userId}) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => VisitsScreen(userId: userId)),
    );
  }

  @override
  State<VisitsScreen> createState() => _VisitsScreenState();
}

enum _Period { today, week, month, lastMonth, all }

class _VisitsScreenState extends State<VisitsScreen> {
  final VisitRepository _repo = VisitRepository();
  final TextEditingController _search = TextEditingController();
  _Period _period = _Period.month;
  bool _table = true;

  late final Stream<List<VisitRecord>> _visits = _repo.watchVisits(widget.userId);
  late final Stream<DsrSheet?> _sheet = _repo.watchSheet(widget.userId);

  static const Map<_Period, String> _periodLabels = {
    _Period.today: 'Today',
    _Period.week: 'This week',
    _Period.month: 'This month',
    _Period.lastMonth: 'Last month',
    _Period.all: 'All',
  };

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _inPeriod(VisitRecord v) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = v.visitDate;
    switch (_period) {
      case _Period.today:
        return !d.isBefore(today);
      case _Period.week:
        final monday = today.subtract(Duration(days: today.weekday - 1));
        return !d.isBefore(monday);
      case _Period.month:
        return !d.isBefore(DateTime(now.year, now.month));
      case _Period.lastMonth:
        final start = DateTime(now.year, now.month - 1);
        final end = DateTime(now.year, now.month);
        return !d.isBefore(start) && d.isBefore(end);
      case _Period.all:
        return true;
    }
  }

  List<VisitRecord> _filter(List<VisitRecord> all) {
    final q = _search.text.trim().toLowerCase();
    return all.where((v) {
      if (!_inPeriod(v)) return false;
      if (q.isEmpty) return true;
      return v.searchFields.any((f) => f.toLowerCase().contains(q));
    }).toList();
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
        title: Text('Visits · DSR', style: AivyUi.title(context).copyWith(fontSize: 19)),
      ),
      body: SafeArea(
        top: false,
        child: StreamBuilder<List<VisitRecord>>(
          stream: _visits,
          builder: (context, snap) {
            final loading = !snap.hasData && !snap.hasError;
            final rows = _filter(snap.data ?? const <VisitRecord>[]);
            return ListView(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 28),
              children: [
                _periodChips(),
                const SizedBox(height: 12),
                _searchBox(),
                const SizedBox(height: 14),
                _Summary(rows: rows),
                const SizedBox(height: 14),
                StreamBuilder<DsrSheet?>(
                  stream: _sheet,
                  builder: (context, sheetSnap) => _ExcelActions(
                    sheet: sheetSnap.data,
                    onOpen: _open,
                  ),
                ),
                const SizedBox(height: 18),
                AivySectionHeader(
                  title: _periodLabels[_period]!,
                  count: rows.length,
                  action: _table ? 'Card view' : 'Table view',
                  onAction: () => setState(() => _table = !_table),
                ),
                if (snap.hasError)
                  const AivyCard(child: AivyEmpty('Could not load visits.', icon: Icons.error_outline))
                else if (loading)
                  const AivyCard(
                    child: Center(
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                  )
                else if (rows.isEmpty)
                  const AivyCard(
                    child: AivyEmpty(
                      'No visits here yet. Tell Aivy "visit record karo" after a client visit.',
                      icon: Icons.storefront_outlined,
                    ),
                  )
                else if (_table)
                  _VisitTable(rows: rows, onTap: (v) => _VisitSheet.open(context, v))
                else
                  for (final v in rows) ...[
                    _VisitCard(visit: v, onTap: () => _VisitSheet.open(context, v)),
                    const SizedBox(height: 10),
                  ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _periodChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final e in _periodLabels.entries) ...[
            _Chip(
              label: e.value,
              selected: _period == e.key,
              onTap: () => setState(() => _period = e.key),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _searchBox() {
    return TextField(
      controller: _search,
      style: AivyUi.body(context),
      decoration: InputDecoration(
        hintText: 'Search client, product, status',
        hintStyle: AivyUi.soft(context),
        prefixIcon: const Icon(Icons.search, size: 19, color: AivyUi.inkFaint),
        suffixIcon: _search.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, size: 17),
                color: AivyUi.inkFaint,
                onPressed: _search.clear,
              ),
        isDense: true,
        filled: true,
        fillColor: AivyUi.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
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
    );
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});

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

/// Three numbers a manager asks for first.
class _Summary extends StatelessWidget {
  const _Summary({required this.rows});

  final List<VisitRecord> rows;

  @override
  Widget build(BuildContext context) {
    final clients = rows.map((v) => v.clientName.toLowerCase()).toSet().length;
    final now = DateTime.now().millisecondsSinceEpoch;
    final followUps = rows.where((v) => v.hasFollowUp && v.followUpMs >= now).length;
    return Row(
      children: [
        Expanded(child: _Tile(label: 'Visits', value: '${rows.length}', color: AivyUi.brand)),
        const SizedBox(width: 10),
        Expanded(child: _Tile(label: 'Clients', value: '$clients', color: AivyUi.info)),
        const SizedBox(width: 10),
        Expanded(child: _Tile(label: 'Follow-ups ahead', value: '$followUps', color: AivyUi.warn)),
      ],
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
          Text(value, style: AivyUi.display(context).copyWith(fontSize: 24, color: color)),
          const SizedBox(height: 2),
          Text(label, style: AivyUi.soft(context), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

/// Download Excel and open the sheet. Both need the sheet to exist, which it
/// does from the first visit saved on the phone with Google allowed.
class _ExcelActions extends StatelessWidget {
  const _ExcelActions({required this.sheet, required this.onOpen});

  final DsrSheet? sheet;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final s = sheet;
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
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AivyUi.radiusSm),
                  ),
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
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AivyUi.radiusSm),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (s == null)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: Text(
              'The Excel file is ready once your first visit is saved with Google allowed.',
              style: AivyUi.soft(context),
            ),
          ),
      ],
    );
  }
}

Color _statusColor(String status) {
  final s = status.toLowerCase();
  if (s.contains('order')) return AivyUi.ok;
  if (s.contains('not interested') || s.contains('lost')) return AivyUi.danger;
  if (s.contains('quotation') || s.contains('demo') || s.contains('hot')) return AivyUi.warn;
  if (s.contains('interest')) return AivyUi.info;
  return AivyUi.inkSoft;
}

String _shortDate(VisitRecord v) =>
    v.dateLabel.isNotEmpty ? v.dateLabel : DateFormat('dd-MMM-yyyy').format(v.visitDate);

String _followUpText(VisitRecord v) =>
    v.hasFollowUp ? DateFormat('dd-MMM-yyyy').format(DateTime.fromMillisecondsSinceEpoch(v.followUpMs)) : '';

/// The sheet, on the phone: same columns, scrolls sideways, tap a row for all
/// of it.
class _VisitTable extends StatelessWidget {
  const _VisitTable({required this.rows, required this.onTap});

  final List<VisitRecord> rows;
  final ValueChanged<VisitRecord> onTap;

  static const List<String> _columns = [
    'Date',
    'Client',
    'Contact',
    'Location',
    'Type',
    'Products',
    'Discussion',
    'Status',
    'Next step',
    'Follow-up',
  ];

  Widget _cell(BuildContext context, String text, {double width = 140, Color? color}) {
    return SizedBox(
      width: width,
      child: Text(
        text.isEmpty ? '—' : text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AivyUi.body(context).copyWith(
          fontSize: 13,
          color: text.isEmpty ? AivyUi.inkFaint : (color ?? AivyUi.ink),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AivyCard(
      padding: EdgeInsets.zero,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          showCheckboxColumn: false,
          headingRowHeight: 40,
          dataRowMinHeight: 44,
          dataRowMaxHeight: 60,
          columnSpacing: 18,
          horizontalMargin: 14,
          headingRowColor: WidgetStateProperty.all(AivyUi.surfaceHigh),
          dividerThickness: 0.5,
          headingTextStyle: AivyUi.label(context).copyWith(color: AivyUi.inkSoft),
          columns: [for (final c in _columns) DataColumn(label: Text(c.toUpperCase()))],
          rows: [
            for (final v in rows)
              DataRow(
                onSelectChanged: (_) => onTap(v),
                cells: [
                  DataCell(_cell(context, _shortDate(v), width: 92)),
                  DataCell(_cell(context, v.clientName, width: 150)),
                  DataCell(_cell(context, v.contactPerson, width: 130)),
                  DataCell(_cell(context, v.location, width: 130)),
                  DataCell(_cell(context, v.visitType, width: 90)),
                  DataCell(_cell(context, v.products, width: 150)),
                  DataCell(_cell(context, v.discussion, width: 200)),
                  DataCell(_cell(context, v.status, width: 120, color: _statusColor(v.status))),
                  DataCell(_cell(context, v.nextStep, width: 160)),
                  DataCell(_cell(context, _followUpText(v), width: 100, color: AivyUi.warn)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _VisitCard extends StatelessWidget {
  const _VisitCard({required this.visit, required this.onTap});

  final VisitRecord visit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final v = visit;
    return AivyCard(
      onTap: onTap,
      accent: v.hasFollowUp ? AivyUi.warn : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(v.clientName, style: AivyUi.title(context), maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              Text(_shortDate(v), style: AivyUi.soft(context)),
            ],
          ),
          if (v.contactPerson.isNotEmpty || v.location.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              [v.contactPerson, v.location].where((s) => s.isNotEmpty).join(' · '),
              style: AivyUi.soft(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (v.products.isNotEmpty || v.discussion.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              [v.products, v.discussion].where((s) => s.isNotEmpty).join(' — '),
              style: AivyUi.body(context),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (v.visitType.isNotEmpty) AivyPill(v.visitType),
              if (v.status.isNotEmpty) AivyPill(v.status, color: _statusColor(v.status)),
              if (v.hasFollowUp)
                AivyPill('Follow-up ${_followUpText(v)}', color: AivyUi.warn, icon: Icons.notifications_active_outlined),
              if (!v.inSheet) const AivyPill('Not in sheet yet', color: AivyUi.inkFaint),
            ],
          ),
        ],
      ),
    );
  }
}

/// Everything about one visit, nothing cut off.
class _VisitSheet extends StatelessWidget {
  const _VisitSheet({required this.visit});

  final VisitRecord visit;

  static Future<void> open(BuildContext context, VisitRecord v) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AivyUi.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AivyUi.radius)),
      ),
      builder: (_) => _VisitSheet(visit: v),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = visit;
    final lines = <MapEntry<String, String>>[
      MapEntry('Date', _shortDate(v)),
      MapEntry('Contact', v.contactPerson),
      MapEntry('Phone', v.contactPhone),
      MapEntry('Location', v.location),
      MapEntry('Visit type', v.visitType),
      MapEntry('Products', v.products),
      MapEntry('Discussion', v.discussion),
      MapEntry('Status', v.status),
      MapEntry('Next step', v.nextStep),
      MapEntry('Follow-up', v.hasFollowUp ? v.followUpLabel : ''),
      MapEntry('DSR sheet', v.inSheet ? 'Added' : 'Will be added when Google is connected'),
    ].where((e) => e.value.isNotEmpty).toList();

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(color: AivyUi.line, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),
            Text(v.clientName, style: AivyUi.title(context).copyWith(fontSize: 20)),
            const SizedBox(height: 14),
            for (final e in lines) ...[
              Text(e.key.toUpperCase(), style: AivyUi.label(context)),
              const SizedBox(height: 3),
              Text(e.value, style: AivyUi.body(context)),
              const SizedBox(height: 12),
            ],
            if (v.contactPhone.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => unawaited(
                  launchUrl(Uri.parse('tel:${v.contactPhone.replaceAll(' ', '')}')),
                ),
                icon: const Icon(Icons.call_outlined, size: 18),
                label: Text('Call ${v.contactPerson.isNotEmpty ? v.contactPerson : v.contactPhone}'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AivyUi.ink,
                  side: const BorderSide(color: AivyUi.line),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
