import 'dart:convert';

import 'package:intl/intl.dart';

import '../models/aivy_ai_response.dart';
import '../../reminders/utils/reminder_time_parser.dart';
import 'extract_inr_amount.dart';

/// Central, fixed templates for all user-visible assistant lines.
/// [type] must be one of: reminder | quotation | followup | greeting | error |
/// info | no_quotation_context
String generateAivyResponse(String type, Map<String, String> data) {
  switch (type) {
    case 'reminder':
      return 'Reminder scheduled for ${data['date_time'] ?? ''}.';
    case 'quotation':
      final base =
          'Quotation saved: ₹${data['amount'] ?? ''} for ${data['client'] ?? ''}.';
      if (data['followup_prompt'] == '1') {
        return '$base Follow-up required?';
      }
      return base;
    case 'followup':
      return 'Follow-up scheduled for ${data['date_time'] ?? ''}.';
    case 'greeting':
      return 'Hello. How can I assist you today?';
    case 'error':
      return "I missed that. Could you rephrase what you'd like me to do?";
    case 'info':
      return data['short_clean_answer'] ?? '';
    case 'no_quotation_context':
      return 'No recent quotation found.';
    case 'payment_local':
      return 'Collection saved: ${data['amount'] ?? ''} from ${data['client'] ?? ''} '
          '(reminder: ${data['when'] ?? ''}).';
    default:
      return generateAivyResponse('error', const {});
  }
}

/// Trim, collapse spaces, capitalize first letter (e.g. "roshan" → "Roshan").
String formatClientDisplayName(String raw) {
  final collapsed = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (collapsed.isEmpty) {
    return collapsed;
  }
  return collapsed[0].toUpperCase() + collapsed.substring(1);
}

/// Title-cases each word (e.g. "rakesh kumar" → "Rakesh Kumar").
/// Preserves all-caps tokens like "PGPL". Keeps short connectors
/// ("for", "with", …) lowercase in the middle of the phrase.
String capitalizeWords(String text) {
  const lowerInMiddle = {
    'for',
    'with',
    'and',
    'or',
    'to',
    'of',
    'in',
    'on',
    'at',
    'a',
    'an',
    'the',
  };
  final collapsed = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (collapsed.isEmpty) {
    return '';
  }
  final parts = collapsed.split(RegExp(r'\s+'));
  return parts
      .asMap()
      .entries
      .map((e) {
        final i = e.key;
        final w = e.value;
        if (w.isEmpty) {
          return w;
        }
        if (w.length > 1 &&
            w == w.toUpperCase() &&
            RegExp(r'^[A-Z0-9.&]+$').hasMatch(w)) {
          return w;
        }
        final lower = w.toLowerCase();
        if (i > 0 &&
            i < parts.length - 1 &&
            lowerInMiddle.contains(lower)) {
          return lower;
        }
        return w[0].toUpperCase() + w.substring(1).toLowerCase();
      })
      .join(' ');
}

/// INR amount for templates (Indian grouping), e.g. 20000 → 20,000.
String formatDisplayInrAmount(double amount) {
  if (amount == amount.roundToDouble()) {
    return NumberFormat('#,##,###', 'en_IN').format(amount.round());
  }
  final fmt = NumberFormat('#,##,###.##', 'en_IN');
  return fmt.format(amount);
}

/// Normalizes model/local-derived info lines: no emoji, trimmed, bounded.
String _cleanInfoAnswer(String raw) {
  var s = stripEmojiLikeSymbols(raw);
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.length > 400) {
    s = '${s.substring(0, 397)}...';
  }
  return s;
}

/// Best-effort emoji / pictograph removal without extra dependencies.
String stripEmojiLikeSymbols(String input) {
  if (input.isEmpty) {
    return input;
  }
  return input
      .replaceAll(
        RegExp(
          r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}\u{FE0F}\u{200D}]',
          unicode: true,
        ),
        '',
      )
      .trim();
}

String _formatAmount(double amount) {
  return formatDisplayInrAmount(amount);
}

String _firstSentence(String text) {
  final t = text.trim();
  if (t.isEmpty) {
    return '';
  }
  final cut = RegExp(r'[.!?](\s|$)').firstMatch(t);
  if (cut != null && cut.start > 0) {
    return t.substring(0, cut.start + 1).trim();
  }
  return t;
}

/// Single user-facing line derived only from structured fields — never from raw cloud prose.
String formatCloudAssistantReply(
  AivyAiResponse response, {
  String? userRawInput,
  double? quotationAmountResolved,
  bool showQuotationFollowUpPrompt = true,
}) {
  final backendAssistantReply = response.assistantReply.trim();
  if (backendAssistantReply.isNotEmpty) {
    return backendAssistantReply;
  }

  final raw = userRawInput?.trim() ?? '';
  final summary = response.summary.trim();
  final client = formatClientDisplayName(response.clientName);

  if (response.memoryCategory == 'quotation' && client.isNotEmpty) {
    final amt = quotationAmountResolved ??
        extractInrAmountFromText(
          '$raw $summary ${response.assistantReply}',
        );
    if (amt != null && amt > 0) {
      return _finalize(
        generateAivyResponse('quotation', {
          'amount': _formatAmount(amt),
          'client': client,
          if (showQuotationFollowUpPrompt) 'followup_prompt': '1',
        }),
        preserveQuotationFollowUpPrompt: showQuotationFollowUpPrompt,
      );
    }
  }

  if (response.reminderSuggestions.isNotEmpty) {
    final r = response.reminderSuggestions.first;
    final scheduled = ReminderTimeParser.resolveScheduledTime(r);
    if (scheduled == null) {
      final title = r.title.trim();
      return _finalize(
        generateAivyResponse('info', {
          'short_clean_answer': title.isNotEmpty
              ? title
              : 'Reminder time is not clear yet.',
        }),
        info: true,
      );
    }
    final when = ReminderTimeParser.formatReminderTime(scheduled);
    final titleLower = r.title.toLowerCase();
    final isFollowUp =
        r.isAutoGenerated ||
        titleLower.contains('follow up') ||
        titleLower.contains('follow-up');
    final kind = isFollowUp ? 'followup' : 'reminder';
    return _finalize(generateAivyResponse(kind, {'date_time': when}));
  }

  final goal = response.goalRecord;
  if (goal != null) {
    final amtStr = _formatAmount(goal.targetAmount);
    final line = _cleanInfoAnswer(
      'Monthly target ₹$amtStr for ${goal.monthKey}.',
    );
    if (line.isNotEmpty) {
      return _finalize(
        generateAivyResponse('info', {'short_clean_answer': line}),
        info: true,
      );
    }
  }

  if (summary.isNotEmpty) {
    final line = _cleanInfoAnswer(_firstSentence(summary));
    if (line.isNotEmpty) {
      return _finalize(
        generateAivyResponse('info', {'short_clean_answer': line}),
        info: true,
      );
    }
  }

  if (response.keyPoints.isNotEmpty) {
    final line = _cleanInfoAnswer(_firstSentence(response.keyPoints.first));
    if (line.isNotEmpty) {
      return _finalize(
        generateAivyResponse('info', {'short_clean_answer': line}),
        info: true,
      );
    }
  }

  return _finalize(generateAivyResponse('error', const {}));
}

String _finalize(
  String text, {
  bool info = false,
  bool preserveQuotationFollowUpPrompt = false,
}) {
  final t = text.trim();
  if (t.isEmpty) {
    return generateAivyResponse('error', const {});
  }
  if (!info) {
    if (preserveQuotationFollowUpPrompt && t.contains('Follow-up required?')) {
      return stripEmojiLikeSymbols(t).trim();
    }
    final one = _firstSentence(t);
    return stripEmojiLikeSymbols(one).trim();
  }
  return stripEmojiLikeSymbols(t).trim();
}

/// User-facing chat line from a cloud [AivyAiResponse]: uses the backend
/// `userReply` only (mapped to [AivyAiResponse.assistantReply] in [AivyAiResponse.fromJson]).
/// Never falls back to summary or structured fields — those stay off the chat surface.
String userReplyOnlyForChat(AivyAiResponse response) {
  final d = response.data;
  if (d != null) {
    if (response.intent == 'total_quotation_today') {
      final c = d['count'];
      if (c is int) {
        return safeChatMessageBody('Aaj aapne $c quotations diye hain.');
      }
      if (c is num) {
        return safeChatMessageBody('Aaj aapne ${c.toInt()} quotations diye hain.');
      }
    } else if (response.intent == 'quotation_names_today') {
      final raw = d['names'];
      if (raw is List && raw.isNotEmpty) {
        final names = raw
            .map((e) => e?.toString().trim() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
        if (names.isNotEmpty) {
          return safeChatMessageBody(
            'Aaj aapne in clients ko quotation diya: ${names.join(', ')}.',
          );
        }
      }
    } else if (response.intent == 'quotation_value_today') {
      final a = d['totalAmount'];
      if (a is num) {
        return safeChatMessageBody(
          'Aaj aapke quotations ka kul jama ${_formatInrForData(a.toDouble())} hai.',
        );
      }
    } else if (response.intent == 'dispatches_today') {
      final c = d['count'];
      if (c is int) {
        return safeChatMessageBody('Aaj aapne $c order dispatch kiye hain.');
      }
      if (c is num) {
        return safeChatMessageBody(
          'Aaj aapne ${c.toInt()} order dispatch kiye hain.',
        );
      }
    } else if (response.intent == 'total_orders_month') {
      final a = d['totalAmount'];
      if (a is num) {
        return safeChatMessageBody(
          'Is maahine aapke orders ka kul jama ${_formatInrForData(a.toDouble())} hai.',
        );
      }
    } else if (response.intent == 'analytics_query' &&
        d['analyticsKind'] == 'payment_due_list') {
      if (d['clientFilterNoMatch'] == true) {
        return safeChatMessageBody(
          'Is client ke liye koi payment due nahi hai',
        );
      }
      final rawRows = d['rows'];
      if (rawRows is! List || rawRows.isEmpty) {
        return safeChatMessageBody('Koi payment due nahi hai');
      }
      final rows = <Map<String, dynamic>>[];
      for (final e in rawRows) {
        if (e is Map) {
          rows.add(Map<String, dynamic>.from(e));
        }
      }
      if (rows.isEmpty) {
        return safeChatMessageBody('Koi payment due nahi hai');
      }
      return safeChatMessageBody(
        formatPaymentList(
          rows,
          paymentQueryUserText: (d['paymentQueryUserText'] ?? '').toString(),
        ),
      );
    } else if (response.intent == 'analytics_query' &&
        d['analyticsKind'] == 'dispatch_line_items') {
      final rawRows = d['rows'];
      if (rawRows is! List || rawRows.isEmpty) {
        final wl = d['windowLabel']?.toString().trim() ?? 'Window';
        return safeChatMessageBody('$wl: koi dispatch line item nahi mila.');
      }
      final n = rawRows.length;
      final lines = <String>[];
      for (var i = 0; i < n && i < 15; i++) {
        final e = rawRows[i];
        if (e is! Map) {
          continue;
        }
        final client = e['client']?.toString() ?? 'Client';
        final amt = e['amount'] is num
            ? (e['amount'] as num).toDouble()
            : 0.0;
        final amtStr = NumberFormat('#,##0', 'en_IN').format(amt.round());
        lines.add('$client — ₹$amtStr');
      }
      final buf = StringBuffer();
      buf.writeln('$n dispatch(es):');
      buf.writeln();
      for (var i = 0; i < lines.length; i++) {
        buf.writeln('${i + 1}. ${lines[i]}');
      }
      return safeChatMessageBody(buf.toString().trimRight());
    }
  }
  final primary = response.assistantReply.trim();
  if (primary.isEmpty) {
    return generateAivyResponse('error', const {});
  }
  return safeChatMessageBody(primary);
}

String _formatInrForData(double amount) {
  return '₹${formatDisplayInrAmount(amount)}';
}

/// One strict list for payment-due (must match [formatPaymentList] in aivyProcess.ts).
String formatPaymentList(
  List<Map<String, dynamic>> rawRows, {
  required String paymentQueryUserText,
}) {
  if (rawRows.isEmpty) {
    return 'Koi payment due nahi hai';
  }
  final wantTotal = RegExp(r'\btotal\b').hasMatch(
    paymentQueryUserText.toLowerCase(),
  );
  num sum = 0;
  for (final e in rawRows) {
    if (e['amount'] is num) {
      sum += e['amount'] as num;
    }
  }
  final buf = StringBuffer();
  if (wantTotal && sum > 0) {
    final totalStr = NumberFormat('#,##0', 'en_IN').format(sum.round());
    buf.writeln('Total ₹$totalStr payment due hai\n');
  }
  final byClient = <String, List<Map<String, dynamic>>>{};
  for (var i = 0; i < rawRows.length && i < 40; i++) {
    final m = Map<String, dynamic>.from(rawRows[i]);
    final c = m['client']?.toString().trim().isNotEmpty == true
        ? m['client']!.toString()
        : 'Unknown';
    byClient.putIfAbsent(c, () => <Map<String, dynamic>>[]).add(m);
  }
  for (final entry in byClient.entries) {
    buf.writeln(entry.key);
    final list = entry.value;
    for (var j = 0; j < list.length && j < 20; j++) {
      final e = list[j];
      final amt = e['amount'] is num
          ? (e['amount'] as num).toDouble()
          : 0.0;
      final label = e['dueDateLabel']?.toString().trim() ?? 'Due date pending';
      final amtStr = NumberFormat('#,##0', 'en_IN').format(amt.round());
      buf.writeln('₹$amtStr — $label');
    }
  }
  return buf.toString().trimRight();
}

/// If legacy data or a model slip stored JSON in the message `text` field, extract
/// `userReply` / `assistantReply` or show the generic error line — never raw JSON.
String safeChatMessageBody(String raw) {
  var t = raw.trim();
  if (t.isEmpty) {
    return generateAivyResponse('error', const {});
  }
  t = _unwrapMarkdownJsonFence(t);
  if (t.startsWith('{')) {
    final extracted = _tryParseUserReplyFromJsonObjectString(t);
    if (extracted != null) {
      return extracted;
    }
    if (_looksLikeJsonObject(t)) {
      return generateAivyResponse('error', const {});
    }
  }
  if (_looksLikeLooseJsonWithKeys(t)) {
    final extracted = _tryParseUserReplyFromJsonObjectString(t);
    if (extracted != null) {
      return extracted;
    }
    return generateAivyResponse('error', const {});
  }
  return t;
}

String _unwrapMarkdownJsonFence(String t) {
  var s = t.trim();
  if (s.startsWith('```')) {
    final firstNl = s.indexOf('\n');
    if (firstNl != -1) {
      s = s.substring(firstNl + 1);
    }
    final end = s.lastIndexOf('```');
    if (end != -1) {
      s = s.substring(0, end);
    }
  }
  return s.trim();
}

bool _looksLikeJsonObject(String t) {
  return t.startsWith('{') && t.contains('}') && t.length > 2;
}

bool _looksLikeLooseJsonWithKeys(String t) {
  return t.contains('"userReply"') || t.contains('"assistantReply"');
}

String? _tryParseUserReplyFromJsonObjectString(String t) {
  try {
    final decoded = jsonDecode(t);
    if (decoded is Map) {
      final m = Map<String, dynamic>.from(
        decoded.map((k, v) => MapEntry(k.toString(), v)),
      );
      final direct = m['userReply'] ?? m['assistantReply'];
      if (direct is String) {
        final u = direct.trim();
        if (u.isNotEmpty) {
          return u;
        }
      }
    }
  } catch (_) {
    // ignore
  }
  return null;
}
