import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';

import '../../../../core/voice/aivy_chat_voice_coordinator.dart';
import '../../models/chat_message.dart';
import '../../utils/aivy_response_formatter.dart';
import '../../../projects/presentation/widgets/project_confirm_card.dart';
import 'package:url_launcher/url_launcher.dart';

class ChatBubble extends StatefulWidget {
  const ChatBubble({
    super.key,
    required this.message,
    this.onOrderDispatchQuickPick,
  });

  final ChatMessage message;
  /// Tapping a listed order sends this text as the user message (e.g. "1" or "2").
  final void Function(String text)? onOrderDispatchQuickPick;

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble> {
  AudioPlayer? _player;
  bool _isPreparing = false;
  String? _audioError;
  bool _transcriptExpanded = false;
  bool _sourcesExpanded = false;

  // Transcripts longer than this get a "Show more / Show less" toggle. The
  // value is tuned for ~2 lines on an average bubble width.
  static const int _transcriptPreviewThreshold = 110;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    final audioUrl = widget.message.audioUrl;
    if (audioUrl == null || audioUrl.trim().isEmpty) {
      return;
    }

    final existingPlayer = _player;
    if (existingPlayer != null && existingPlayer.playing) {
      await existingPlayer.pause();
      return;
    }

    if (existingPlayer != null) {
      await existingPlayer.play();
      return;
    }

    setState(() {
      _isPreparing = true;
      _audioError = null;
    });

    final player = AudioPlayer();
    try {
      await player.setUrl(audioUrl);
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
      });
      await player.play();
    } catch (error) {
      await player.dispose();
      if (!mounted) {
        return;
      }
      setState(() {
        _audioError = 'Unable to play voice message.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isPreparing = false;
        });
      }
    }
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildVoiceBody(Color textColor) {
    final player = _player;
    final fallbackDuration = Duration(
      milliseconds: widget.message.durationMs ?? 0,
    );

    if (_audioError != null) {
      return Text(_audioError!, style: TextStyle(color: textColor));
    }

    if (player == null) {
      final label = fallbackDuration == Duration.zero
          ? 'Voice message'
          : _formatDuration(fallbackDuration);
      return Text(label, style: TextStyle(color: textColor, height: 1.35));
    }

    return StreamBuilder<Duration>(
      stream: player.positionStream,
      builder: (context, positionSnapshot) {
        final position = positionSnapshot.data ?? Duration.zero;
        return StreamBuilder<PlayerState>(
          stream: player.playerStateStream,
          builder: (context, stateSnapshot) {
            final state = stateSnapshot.data;
            final isCompleted =
                state?.processingState == ProcessingState.completed;
            final total = player.duration ?? fallbackDuration;
            final shownPosition = isCompleted ? total : position;
            final safeTotal = total > Duration.zero
                ? total
                : fallbackDuration > Duration.zero
                ? fallbackDuration
                : const Duration(seconds: 1);
            final progress =
                (shownPosition.inMilliseconds / safeTotal.inMilliseconds).clamp(
                  0.0,
                  1.0,
                );
            final timeText = _formatDuration(
              total > Duration.zero ? total : fallbackDuration,
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: progress.toDouble(),
                  minHeight: 3,
                  backgroundColor: textColor.withValues(alpha: 0.18),
                  valueColor: AlwaysStoppedAnimation<Color>(textColor),
                ),
                const SizedBox(height: 8),
                Text(
                  timeText,
                  style: TextStyle(color: textColor, height: 1.35),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildTranscriptSection(Color textColor) {
    final message = widget.message;
    final status = message.transcriptStatus;
    final transcript = message.transcript?.trim() ?? '';
    final mutedColor = textColor.withValues(alpha: 0.75);

    if (status == TranscriptStatus.processing) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: _TranscribingShimmer(baseColor: mutedColor),
      );
    }

    if (status == TranscriptStatus.failed) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 14,
              color: mutedColor,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Transcription unavailable',
                style: TextStyle(
                  color: mutedColor,
                  fontStyle: FontStyle.italic,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (transcript.isEmpty) {
      return const SizedBox.shrink();
    }

    final isLong = transcript.length > _transcriptPreviewThreshold;
    final showToggle = isLong;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: textColor.withValues(alpha: 0.22),
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  textColor.withValues(alpha: 0.14),
                  textColor.withValues(alpha: 0.06),
                ],
              ),
            ),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              alignment: Alignment.topLeft,
              child: Text(
                transcript,
                maxLines: _transcriptExpanded ? null : 2,
                overflow: _transcriptExpanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: TextStyle(
                  color: textColor,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ),
          ),
          if (showToggle)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() {
                  _transcriptExpanded = !_transcriptExpanded;
                });
              },
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _transcriptExpanded ? 'Show less' : 'Show more',
                      style: TextStyle(
                        color: mutedColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      _transcriptExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: mutedColor,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _titleForAnalyticsKind(String? k) {
    return switch (k) {
      'client_rank_business' => 'Top clients',
      'client_rank_pending' => 'Highest pending',
      'week_payment_followup_list' => 'This week — payments',
      'risky_clients_list' => 'Risky clients',
      'overdue_payments_list' => 'Overdue',
      'followup_today_list' => 'Follow-up',
      'pending_orders_list' => 'Pending orders',
      'quotation_line_items' => 'Quotations',
      'payment_due_list' => 'Payment due',
      'daily_status_summary' => 'Status',
      _ => 'Details',
    };
  }

  List<(String, String)> _rowsFromStatusSnapshot(Map<String, dynamic> snap) {
    final fullText = (snap['fullText'] as String? ?? '').trim();
    if (fullText.isEmpty) {
      return const [];
    }
    final out = <(String, String)>[];
    for (var line in fullText.split('\n')) {
      line = line.replaceFirst(
        RegExp(r'^[•\-\s\u2022]+', unicode: true),
        '',
      ).trim();
      if (line.isEmpty) {
        continue;
      }
      final i = line.indexOf(':');
      if (i <= 0) {
        out.add((line, '—'));
        continue;
      }
      out.add((
        line.substring(0, i).trim(),
        line.substring(i + 1).trim(),
      ));
    }
    return out;
  }

  /// Full-status snapshot: two columns (metric · value) like a compact report.
  Widget _buildStatusSnapshotTable(
    Color textColor,
    Map<String, dynamic> aivy,
  ) {
    final snap = aivy['dailySummarySnapshot'];
    if (snap is! Map) {
      return Text(
        safeChatMessageBody(''),
        style: TextStyle(color: textColor, height: 1.35),
      );
    }
    final m = Map<String, dynamic>.from(snap);
    final one = (m['oneLiner'] as String? ?? '').trim();
    final pairs = _rowsFromStatusSnapshot(m);
    if (pairs.isEmpty) {
      return Text(
        one.isNotEmpty
            ? safeChatMessageBody(one)
            : safeChatMessageBody(''),
        style: TextStyle(color: textColor, height: 1.35),
      );
    }
    final border = BorderSide(
      color: textColor.withValues(alpha: 0.22),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (one.isNotEmpty) ...[
          Text(
            one,
            style: TextStyle(
              color: textColor,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
        ],
        Table(
          border: TableBorder(horizontalInside: border, bottom: border, top: border),
          columnWidths: const {
            0: FlexColumnWidth(1.1),
            1: FlexColumnWidth(1.0),
          },
          children: [
            TableRow(
              decoration: BoxDecoration(
                color: textColor.withValues(alpha: 0.08),
              ),
              children: [
                _paymentTableHeader('Item', textColor),
                _paymentTableHeader('Value', textColor),
              ],
            ),
            ...List.generate(
              pairs.length,
              (i) {
                final p = pairs[i];
                final s = TextStyle(
                  color: textColor,
                  fontSize: 12.5,
                  height: 1.3,
                );
                return TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                      child: Text('${i + 1}. ${p.$1}', style: s),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                      child: Text(
                        p.$2,
                        textAlign: TextAlign.end,
                        style: s,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  /// True when at least one analytics row carries a positive INR amount.
  static bool _analyticsRowsHavePositiveAmount(List<dynamic> rawRows) {
    for (final cell in rawRows) {
      if (cell is! Map) {
        continue;
      }
      final m = Map<String, dynamic>.from(cell);
      final amountRaw = m['amount'];
      final num? amount =
          amountRaw is num ? amountRaw : num.tryParse(amountRaw.toString());
      if (amount != null && amount > 0) {
        return true;
      }
    }
    return false;
  }

  /// Client + amount (and optional 4th column) — used for most analytics list intents.
  Widget _buildClientAmountOrDateTable(
    Color textColor,
    String title,
    List<dynamic> rawRows, {
    required bool withDate,
    bool showAmountColumn = true,
    int maxRows = 30,
  }) {
    var tableRows = rawRows.length > maxRows ? rawRows.sublist(0, maxRows) : rawRows;
    final border = BorderSide(
      color: textColor.withValues(alpha: 0.22),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            color: textColor,
            height: 1.35,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Table(
          border: TableBorder(horizontalInside: border, bottom: border, top: border),
          columnWidths: withDate
              ? (showAmountColumn
                  ? const {
                      0: FixedColumnWidth(32),
                      1: FlexColumnWidth(2.0),
                      2: FixedColumnWidth(102),
                      3: FixedColumnWidth(88),
                    }
                  : const {
                      0: FixedColumnWidth(32),
                      1: FlexColumnWidth(2.4),
                      2: FixedColumnWidth(104),
                    })
              : const {
                  0: FixedColumnWidth(32),
                  1: FlexColumnWidth(2.2),
                  2: FixedColumnWidth(100),
                },
          children: [
            TableRow(
              decoration: BoxDecoration(
                color: textColor.withValues(alpha: 0.08),
              ),
              children: [
                _paymentTableHeader('#', textColor),
                _paymentTableHeader('Name', textColor),
                if (showAmountColumn || !withDate) _paymentTableHeader('Amount', textColor),
                if (withDate && showAmountColumn) _paymentTableHeader('Date', textColor),
                if (withDate && !showAmountColumn) _paymentTableHeader('When', textColor),
              ],
            ),
            ...List.generate(
              tableRows.length,
              (i) {
                return _clientAmountDataRow(
                  i,
                  tableRows[i],
                  textColor,
                  withDate: withDate,
                  showAmountColumn: showAmountColumn,
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  TableRow _clientAmountDataRow(
    int index,
    Object? cell,
    Color textColor, {
    required bool withDate,
    bool showAmountColumn = true,
  }) {
    if (cell is! Map) {
      final n = withDate ? (showAmountColumn ? 4 : 3) : 3;
      return TableRow(
        children: List.generate(
          n,
          (_) => const SizedBox.shrink(),
        ),
      );
    }
    final m = Map<String, dynamic>.from(cell);
    final client = m['client']?.toString() ?? '—';
    final amountRaw = m['amount'];
    final num? amount = amountRaw is num
        ? amountRaw
        : num.tryParse(amountRaw.toString());
    final hasMoney = amount != null && amount > 0;
    final inr = hasMoney ? formatDisplayInrAmount(amount.toDouble()) : '—';
    final dateLabel = (m['dueDateLabel'] as String? ?? m['date'] as String? ?? '—')
        .toString();
    final s = TextStyle(color: textColor, height: 1.3, fontSize: 12.5);
    if (!withDate) {
      return TableRow(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Text('${index + 1}.', style: s),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Text(client, style: s),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Text(
              hasMoney ? '₹$inr' : '—',
              style: s,
            ),
          ),
        ],
      );
    }
    if (!showAmountColumn) {
      return TableRow(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Text('${index + 1}.', style: s),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Text(client, style: s),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Text(
              dateLabel,
              textAlign: TextAlign.end,
              style: s,
            ),
          ),
        ],
      );
    }
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Text('${index + 1}.', style: s),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Text(client, style: s),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Text(
            hasMoney ? '₹$inr' : '—',
            style: s,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Text(
            dateLabel,
            textAlign: TextAlign.end,
            style: s,
          ),
        ),
      ],
    );
  }

  /// Dispatches with amounts (analytics `dispatch_line_items`).
  Widget _buildDispatchLineItemsPanel(
    Color textColor,
    Map<String, dynamic> aivy,
  ) {
    final rawRows = aivy['rows'];
    if (rawRows is! List || rawRows.isEmpty) {
      final wl = aivy['windowLabel']?.toString().trim() ?? 'Window';
      return Text(
        '$wl: koi dispatch line item nahi mila.',
        style: TextStyle(color: textColor, height: 1.35),
      );
    }
    final tableRows =
        rawRows.length > 15 ? rawRows.sublist(0, 15) : rawRows;
    final border = BorderSide(
      color: textColor.withValues(alpha: 0.22),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${rawRows.length} dispatch(es)',
          style: TextStyle(
            color: textColor,
            height: 1.35,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Table(
          border: TableBorder(horizontalInside: border, bottom: border, top: border),
          columnWidths: const {
            0: FixedColumnWidth(32),
            1: FlexColumnWidth(2.2),
            2: FixedColumnWidth(100),
          },
          children: [
            TableRow(
              decoration: BoxDecoration(
                color: textColor.withValues(alpha: 0.08),
              ),
              children: [
                _paymentTableHeader('#', textColor),
                _paymentTableHeader('Name', textColor),
                _paymentTableHeader('Amount', textColor),
              ],
            ),
            ...List.generate(
              tableRows.length,
              (i) => _dispatchLineDataRow(i, tableRows[i], textColor),
            ),
          ],
        ),
      ],
    );
  }

  TableRow _dispatchLineDataRow(
    int index,
    Object? cell,
    Color textColor,
  ) {
    if (cell is! Map) {
      return TableRow(
        children: List.generate(3, (_) => const SizedBox.shrink()),
      );
    }
    final client = cell['client']?.toString() ?? 'Client';
    final amt = cell['amount'] is num
        ? (cell['amount'] as num).toDouble()
        : 0.0;
    final amtStr = NumberFormat('#,##0', 'en_IN').format(amt.round());
    final s = TextStyle(color: textColor, height: 1.3, fontSize: 12.5);
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Text('${index + 1}.', style: s),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Text(client, style: s),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Text('₹$amtStr', style: s),
        ),
      ],
    );
  }

  static Widget _paymentTableHeader(String label, Color textColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
      ),
    );
  }

  /// Tappable rows when the server returned [aivyData.orders] for dispatch selection.
  Widget _buildTextBody({
    required BuildContext context,
    required Color textColor,
    required ChatMessage message,
  }) {
    if (message.role == ChatRole.assistant) {
      final aivy = message.aivyData;
      if (aivy != null) {
        final quick = aivy['quickReplies'];
        if (quick is List && quick.isNotEmpty) {
          if (kDebugMode &&
              quick.map((e) => e.toString()).any(
                    (s) => s == 'Confirm' || s == 'Edit' || s == 'Cancel',
                  )) {
            debugPrint(
              '[AIVY_TRACE_CONFIRM] ChatBubble _buildTextBody quickReplies '
              'flowControlled=${aivy['controlledFlow']} pickNull=${widget.onOrderDispatchQuickPick == null} '
              'labels=$quick',
            );
          }
          final pick = widget.onOrderDispatchQuickPick;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                safeChatMessageBody(message.text),
                style: TextStyle(color: textColor, height: 1.35),
              ),
              if (pick != null) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final q in quick)
                      Material(
                        color: const Color(0xFF1E293B).withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(20),
                        child: InkWell(
                          onTap: () => pick(q.toString()),
                          borderRadius: BorderRadius.circular(20),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            child: Text(
                              q.toString(),
                              style: TextStyle(
                                color: textColor,
                                fontWeight: FontWeight.w500,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          );
        }
        final k = aivy['analyticsKind']?.toString();
        if (k == 'dispatch_line_items') {
          return _buildDispatchLineItemsPanel(textColor, aivy);
        }
        if (k == 'daily_status_summary' && aivy['dailySummarySnapshot'] != null) {
          return _buildStatusSnapshotTable(textColor, aivy);
        }
        final rawRows = aivy['rows'];
        if (rawRows is List && rawRows.isNotEmpty) {
          const nameAmountOnly = <String>{
            'client_rank_business',
            'client_rank_pending',
            'risky_clients_list',
            'quotation_line_items',
          };
          const nameAmountDate = <String>{
            'overdue_payments_list',
            'week_payment_followup_list',
            'followup_today_list',
            'pending_orders_list',
            'payment_due_list',
          };
          if (k != null && nameAmountOnly.contains(k)) {
            return _buildClientAmountOrDateTable(
              textColor,
              _titleForAnalyticsKind(k),
              rawRows,
              withDate: false,
            );
          }
          if (k != null && nameAmountDate.contains(k)) {
            final showAmount = _analyticsRowsHavePositiveAmount(rawRows);
            final table = _buildClientAmountOrDateTable(
              textColor,
              _titleForAnalyticsKind(k),
              rawRows,
              withDate: true,
              showAmountColumn: showAmount,
            );
            if (k == 'payment_due_list') {
              final tot = aivy['totalAmount'];
              if (tot is num && tot > 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    table,
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        'Total — ₹${formatDisplayInrAmount(tot.toDouble())}',
                        style: TextStyle(
                          color: textColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                );
              }
            }
            return table;
          }
        }
        if (k == 'payment_due_list') {
          return Text(
            safeChatMessageBody(message.text),
            style: TextStyle(color: textColor, height: 1.35),
          );
        }
      }
    }
    final pick = widget.onOrderDispatchQuickPick;
    final rows = _dispatchOrderPickerRows(message.aivyData);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          safeChatMessageBody(message.text),
          style: TextStyle(color: textColor, height: 1.35),
        ),
        if (rows != null &&
            pick != null &&
            message.role == ChatRole.assistant) ...[
          const SizedBox(height: 10),
          ...rows.map(
            (r) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => pick(r.indexText),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFF34D399).withValues(alpha: 0.35),
                      ),
                      color: const Color(0xFF064E3B).withValues(alpha: 0.25),
                    ),
                    child: Text(
                      r.label,
                      style: TextStyle(
                        color: textColor,
                        height: 1.3,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final isUser = message.role == ChatRole.user;
    final colorScheme = Theme.of(context).colorScheme;
    const userText = Color(0xFFF8FAFC);
    final textColor = isUser ? userText : colorScheme.onSurface;
    final isVoice = message.type == ChatMessageType.voice;
    final timeLabel = _formatMessageTime(message.createdAtMs);
    final hasAudioUrl =
        message.audioUrl != null && message.audioUrl!.trim().isNotEmpty;
    final isPlaying = _player?.playing ?? false;

    final content = isVoice
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed:
                        hasAudioUrl && !_isPreparing ? _togglePlayback : null,
                    icon: _isPreparing
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: textColor,
                            ),
                          )
                        : Icon(
                            isPlaying ? Icons.pause : Icons.play_arrow,
                            color: textColor,
                          ),
                  ),
                  const SizedBox(width: 4),
                  Flexible(child: _buildVoiceBody(textColor)),
                ],
              ),
              _buildTranscriptSection(textColor),
            ],
          )
        : _buildTextBody(
            context: context,
            textColor: textColor,
            message: message,
          );

    var wrappedContent = content;
    if (!isVoice &&
        !isUser &&
        message.role == ChatRole.assistant) {
      final raw = message.aivyData?['ttsAudioUrl'];
      final ttsUrl = raw is String ? raw.trim() : '';
      if (ttsUrl.isNotEmpty) {
        wrappedContent = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _AssistantTtsRow(textColor: textColor, audioUrl: ttsUrl),
            const SizedBox(height: 8),
            content,
          ],
        );
      }
    }

    const radius = 18.0;

    final metaRow = _buildMetaRow(
      context: context,
      isUser: isUser,
      timeLabel: timeLabel,
      intentTag: message.intentTag,
      textColor: textColor,
    );

    final aivy = message.aivyData;
    final sources = aivy != null ? aivy['sources'] as List<dynamic>? : null;
    final projectItems = <Map<String, dynamic>>[];
    if (aivy != null && aivy['projectDraft'] == true && aivy['items'] is List) {
      for (final e in aivy['items'] as List) {
        if (e is Map) {
          projectItems.add(Map<String, dynamic>.from(e));
        }
      }
    }

    final padded = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          metaRow,
          const SizedBox(height: 6),
          wrappedContent,
          if (projectItems.isNotEmpty)
            ProjectConfirmCard(
              projectName: '${aivy?['projectName'] ?? ''}',
              client: '${aivy?['client'] ?? ''}',
              items: projectItems,
            ),
          if (sources != null && sources.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 6),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() {
                  _sourcesExpanded = !_sourcesExpanded;
                });
              },
              child: Row(
                children: [
                  const Icon(Icons.language_rounded, color: Color(0xFF10B981), size: 14),
                  const SizedBox(width: 6),
                  Text(
                    'Google Search Sources',
                    style: TextStyle(
                      color: const Color(0xFF10B981),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _sourcesExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: const Color(0xFF10B981),
                  ),
                ],
              ),
            ),
            if (_sourcesExpanded) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final src in sources)
                    if (src is Map) ...[
                      Builder(
                        builder: (context) {
                          final title = src['title']?.toString() ?? 'Web Result';
                          final url = src['link']?.toString() ?? '';
                          String domain = '';
                          try {
                            final uri = Uri.parse(url);
                            domain = uri.host.replaceFirst('www.', '');
                          } catch (_) {
                            domain = 'link';
                          }

                          return InkWell(
                            onTap: url.isEmpty
                                ? null
                                : () async {
                                    final uri = Uri.parse(url);
                                    if (await canLaunchUrl(uri)) {
                                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                                    }
                                  },
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.05),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.08),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.link_rounded, color: Colors.white60, size: 10),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      domain.isNotEmpty ? domain : title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }
                      ),
                    ],
                ],
              ),
            ],
          ],
        ],
      ),
    );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          child: isUser
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF7C3AED),
                        Color(0xFF5B21B6),
                        Color(0xFF4C1D95),
                      ],
                      stops: [0.0, 0.5, 1.0],
                    ),
                    border: Border.all(
                      color: const Color(0xFFE9D5FF).withValues(alpha: 0.32),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF6D28D9).withValues(alpha: 0.4),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: padded,
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(radius),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(radius),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            const Color(0xFF0A0A12).withValues(alpha: 0.9),
                            const Color(0xFF141824).withValues(alpha: 0.85),
                          ],
                        ),
                        border: Border.all(
                          color: message.isError
                              ? const Color(0xFFF47174).withValues(alpha: 0.55)
                              : Colors.white.withValues(alpha: 0.1),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: (message.isError
                                    ? const Color(0xFFDC2626)
                                    : const Color(0xFF6366F1))
                                .withValues(alpha: message.isError ? 0.2 : 0.14),
                            blurRadius: message.isError ? 20 : 22,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: padded,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  String _formatMessageTime(int createdAtMs) {
    if (createdAtMs <= 0) {
      return '';
    }
    final local = DateTime.fromMillisecondsSinceEpoch(createdAtMs).toLocal();
    return DateFormat('h:mm a').format(local);
  }

  Widget _buildMetaRow({
    required BuildContext context,
    required bool isUser,
    required String timeLabel,
    required Color textColor,
    ChatIntentTag? intentTag,
  }) {
    final senderStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: textColor.withValues(alpha: 0.75),
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        );
    final timeStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: textColor.withValues(alpha: 0.55),
          fontSize: 11,
        );

    final name = isUser ? 'You' : 'Aivy';
    if (isUser) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(name, style: senderStyle),
          if (timeLabel.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text('· $timeLabel', style: timeStyle),
          ],
        ],
      );
    }
    return Row(
      children: [
        Text(name, style: senderStyle),
        if (timeLabel.isNotEmpty) ...[
          const SizedBox(width: 6),
          Text('· $timeLabel', style: timeStyle),
        ],
        if (intentTag != null) ...[
          const SizedBox(width: 8),
          _IntentPill(tag: intentTag),
        ],
        const Spacer(),
      ],
    );
  }
}

class _OrderPickRow {
  const _OrderPickRow({required this.indexText, required this.label});

  final String indexText;
  final String label;
}

List<_OrderPickRow>? _dispatchOrderPickerRows(Map<String, dynamic>? aivy) {
  if (aivy == null) {
    return null;
  }
  final raw = aivy['orders'];
  if (raw is! List) {
    return null;
  }
  final out = <_OrderPickRow>[];
  for (final e in raw) {
    if (e is! Map) {
      continue;
    }
    final m = Map<String, dynamic>.from(e);
    final idx = m['index'];
    var n = idx is int ? idx : (idx is num ? idx.toInt() : int.tryParse('$idx'));
    if (n == null) {
      continue;
    }
    if (n < 1) {
      continue;
    }
    final amount = m['amount'];
    final num? amt = amount is num ? amount : num.tryParse('$amount');
    final date = m['date']?.toString().trim() ?? '';
    final inr = amt != null
        ? formatDisplayInrAmount(amt.toDouble())
        : '—';
    out.add(
      _OrderPickRow(
        indexText: '$n',
        label: '[$n]  ₹$inr – $date',
      ),
    );
  }
  if (out.isEmpty) {
    return null;
  }
  return out;
}

class _IntentPill extends StatelessWidget {
  const _IntentPill({required this.tag});

  final ChatIntentTag tag;

  @override
  Widget build(BuildContext context) {
    final String label;
    final Color fg;
    final Color bg;
    switch (tag) {
      case ChatIntentTag.jobDispatch:
        label = 'Job dispatch';
        fg = const Color(0xFF5EEAD4);
        bg = const Color(0xFF0F766E).withValues(alpha: 0.45);
        break;
      case ChatIntentTag.paymentDue:
        label = 'Payment due';
        fg = const Color(0xFFFCD34D);
        bg = const Color(0xFF92400E).withValues(alpha: 0.5);
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
class _AssistantTtsRow extends StatelessWidget {
  const _AssistantTtsRow({required this.textColor, required this.audioUrl});

  final Color textColor;
  final String audioUrl;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => AivyChatVoiceCoordinator.instance.playUrl(audioUrl),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: const Color(0xFF22D3EE).withValues(alpha: 0.35),
            ),
            color: const Color(0xFF0F172A).withValues(alpha: 0.55),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.volume_up_rounded, size: 18, color: textColor),
              const SizedBox(width: 8),
              Text(
                'Play Aivy voice',
                style: TextStyle(
                  color: textColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A lightweight inline shimmer used while a voice message is being
/// transcribed. Keeps its own [AnimationController] so the animation
/// stays smooth even while the parent bubble rebuilds from stream data.
class _TranscribingShimmer extends StatefulWidget {
  const _TranscribingShimmer({required this.baseColor});

  final Color baseColor;

  @override
  State<_TranscribingShimmer> createState() => _TranscribingShimmerState();
}

class _TranscribingShimmerState extends State<_TranscribingShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.baseColor.withValues(alpha: 0.35);
    final highlight = widget.baseColor;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final pulse =
            0.5 + 0.5 * math.sin(_controller.value * math.pi * 2);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF6366F1)
                    .withValues(alpha: 0.12 + 0.22 * pulse),
                blurRadius: 10 + 10 * pulse,
                spreadRadius: -1,
              ),
              BoxShadow(
                color: const Color(0xFF22D3EE)
                    .withValues(alpha: 0.08 + 0.14 * pulse),
                blurRadius: 14 + 8 * pulse,
              ),
            ],
          ),
          child: child,
        );
      },
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.graphic_eq_rounded,
            size: 14,
            color: widget.baseColor,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final t = _controller.value;
                return ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (bounds) {
                    return LinearGradient(
                      colors: [base, highlight, base],
                      stops: const [0.25, 0.5, 0.75],
                      begin: Alignment(-1.0 - 1.5 + 3.0 * t, 0),
                      end: Alignment(1.0 - 1.5 + 3.0 * t, 0),
                    ).createShader(
                      Rect.fromLTWH(0, 0, bounds.width, bounds.height),
                    );
                  },
                  child: child,
                );
              },
              child: Text(
                'Transcribing…',
                style: TextStyle(
                  color: widget.baseColor,
                  fontStyle: FontStyle.italic,
                  height: 1.3,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
