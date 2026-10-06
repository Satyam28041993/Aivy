import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/design/aivy_ui.dart';

/// Every Gemini call Aivy made for this user: what went in, what came out,
/// the tokens, and what it would cost at Google's live paid-tier price.
///
/// Written by `functions/src/agent/aiUsage.ts` — one row per chat turn and per
/// morning brief. The cost is an estimate from Gemini's own token counts; on
/// the free tier nothing is actually billed.
class AiUsageScreen extends StatefulWidget {
  const AiUsageScreen({super.key, required this.userId});

  final String userId;

  static Future<void> open(BuildContext context, {required String userId}) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => AiUsageScreen(userId: userId)),
    );
  }

  @override
  State<AiUsageScreen> createState() => _AiUsageScreenState();
}

enum _Period { today, month, all }

class _AiUsageScreenState extends State<AiUsageScreen> {
  _Period _period = _Period.today;

  late final Stream<List<_UsageRow>> _rows = FirebaseFirestore.instance
      .collection('users')
      .doc(widget.userId)
      .collection('aiUsage')
      .orderBy('atMs', descending: true)
      .limit(500)
      .snapshots()
      .map((s) => s.docs.map((d) => _UsageRow.fromMap(d.data())).toList());

  static const Map<_Period, String> _labels = {
    _Period.today: 'Today',
    _Period.month: 'This month',
    _Period.all: 'Last 500',
  };

  bool _inPeriod(_UsageRow r) {
    final now = DateTime.now();
    switch (_period) {
      case _Period.today:
        return !r.at.isBefore(DateTime(now.year, now.month, now.day));
      case _Period.month:
        return !r.at.isBefore(DateTime(now.year, now.month));
      case _Period.all:
        return true;
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
        title: Text('AI usage & cost', style: AivyUi.title(context).copyWith(fontSize: 19)),
      ),
      body: SafeArea(
        top: false,
        child: StreamBuilder<List<_UsageRow>>(
          stream: _rows,
          builder: (context, snap) {
            final rows = (snap.data ?? const <_UsageRow>[]).where(_inPeriod).toList();
            final usd = rows.fold<double>(0, (a, r) => a + r.costUsd);
            final inr = rows.fold<double>(0, (a, r) => a + r.costInr);
            final tokensIn = rows.fold<int>(0, (a, r) => a + r.inputTokens);
            final tokensOut = rows.fold<int>(0, (a, r) => a + r.outputTokens + r.thinkingTokens);
            return ListView(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 28),
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final e in _labels.entries)
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
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(child: _Tile(label: 'Cost (₹ approx)', value: '₹${inr.toStringAsFixed(2)}', color: AivyUi.ok)),
                    const SizedBox(width: 10),
                    Expanded(child: _Tile(label: 'Cost (USD)', value: '\$${usd.toStringAsFixed(4)}', color: AivyUi.info)),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: _Tile(label: 'AI calls', value: '${rows.length}', color: AivyUi.brand)),
                    const SizedBox(width: 10),
                    Expanded(child: _Tile(label: 'Tokens in', value: _compact(tokensIn), color: AivyUi.inkSoft)),
                    const SizedBox(width: 10),
                    Expanded(child: _Tile(label: 'Tokens out', value: _compact(tokensOut), color: AivyUi.inkSoft)),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Gemini 2.5 Flash at Google\'s paid price: \$0.30 per million tokens in, \$2.50 out '
                  '(thinking included), ₹88 to the dollar. "In" counts everything sent — Aivy\'s '
                  'instructions, the chat so far and tool results — not only your message, which is why '
                  'it is much larger than what you typed. On the free tier nothing is billed.',
                  style: AivyUi.soft(context),
                ),
                const SizedBox(height: 18),
                AivySectionHeader(title: 'Calls', count: rows.length),
                if (!snap.hasData && !snap.hasError)
                  const AivyCard(
                    child: Center(
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  )
                else if (snap.hasError)
                  const AivyCard(child: AivyEmpty('Could not load usage.', icon: Icons.error_outline))
                else if (rows.isEmpty)
                  const AivyCard(
                    child: AivyEmpty('No AI calls here yet. Each message to Aivy appears here.', icon: Icons.memory),
                  )
                else
                  for (final r in rows) ...[
                    _UsageCard(row: r),
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

String _compact(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

class _UsageRow {
  const _UsageRow({
    required this.at,
    required this.source,
    required this.input,
    required this.output,
    required this.tools,
    required this.inputTokens,
    required this.outputTokens,
    required this.thinkingTokens,
    required this.calls,
    required this.costUsd,
    required this.costInr,
  });

  final DateTime at;
  final String source;
  final String input;
  final String output;
  final List<String> tools;
  final int inputTokens;
  final int outputTokens;
  final int thinkingTokens;
  final int calls;
  final double costUsd;
  final double costInr;

  static int _i(Object? v) => v is num ? v.toInt() : 0;
  static double _d(Object? v) => v is num ? v.toDouble() : 0;

  factory _UsageRow.fromMap(Map<String, dynamic> d) {
    return _UsageRow(
      at: DateTime.fromMillisecondsSinceEpoch(_i(d['atMs'])),
      source: '${d['source'] ?? 'chat'}',
      input: '${d['input'] ?? ''}',
      output: '${d['output'] ?? ''}',
      tools: [
        if (d['tools'] is List)
          for (final t in d['tools'] as List)
            if (t is String) t,
      ],
      inputTokens: _i(d['inputTokens']),
      outputTokens: _i(d['outputTokens']),
      thinkingTokens: _i(d['thinkingTokens']),
      calls: _i(d['calls']),
      costUsd: _d(d['costUsd']),
      costInr: _d(d['costInr']),
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
            child: Text(value, style: AivyUi.display(context).copyWith(fontSize: 22, color: color)),
          ),
          const SizedBox(height: 2),
          Text(label, style: AivyUi.soft(context), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

/// One call: the time and cost up top; tap to read the input and the output.
class _UsageCard extends StatefulWidget {
  const _UsageCard({required this.row});

  final _UsageRow row;

  @override
  State<_UsageCard> createState() => _UsageCardState();
}

class _UsageCardState extends State<_UsageCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    return AivyCard(
      onTap: () => setState(() => _open = !_open),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(DateFormat('d MMM, h:mm a').format(r.at), style: AivyUi.soft(context)),
              const SizedBox(width: 8),
              AivyPill(r.source == 'brief' ? 'Brief' : 'Chat', color: AivyUi.brand),
              const Spacer(),
              Text(
                '₹${r.costInr.toStringAsFixed(3)}',
                style: AivyUi.body(context).copyWith(
                  fontWeight: FontWeight.w600,
                  color: AivyUi.ok,
                  fontFeatures: AivyUi.tabular,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            r.input,
            style: AivyUi.body(context),
            maxLines: _open ? null : 2,
            overflow: _open ? null : TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            '${_compact(r.inputTokens)} in · ${_compact(r.outputTokens)} out'
            '${r.thinkingTokens > 0 ? ' · ${_compact(r.thinkingTokens)} thinking' : ''}'
            ' · ${r.calls} call${r.calls == 1 ? '' : 's'} · \$${r.costUsd.toStringAsFixed(5)}',
            style: AivyUi.soft(context).copyWith(fontFeatures: AivyUi.tabular),
          ),
          if (_open) ...[
            if (r.tools.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('TOOLS', style: AivyUi.label(context)),
              const SizedBox(height: 2),
              Text(r.tools.join(', '), style: AivyUi.soft(context)),
            ],
            const SizedBox(height: 10),
            Text('OUTPUT', style: AivyUi.label(context)),
            const SizedBox(height: 2),
            SelectableText(r.output.isEmpty ? '—' : r.output, style: AivyUi.body(context)),
          ],
        ],
      ),
    );
  }
}
