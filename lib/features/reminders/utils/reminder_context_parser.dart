import '../../chat/utils/aivy_response_formatter.dart';
import '../../chat/utils/extract_inr_amount.dart';

/// Structured NLP output for Hinglish / English reminder sentences.
/// E.g. "Rahul ko call karna hai artwork ke liye aaj 3 baje reminder laga do"
/// → call client Rahul, purpose artwork, clean title "Call Rahul",
///   description "Artwork discussion".
class ReminderNlpResult {
  const ReminderNlpResult({
    required this.action,
    required this.type,
    required this.title,
    required this.isStructured,
    this.client = '',
    this.purpose,
    this.description,
  });

  /// e.g. `call`, `payment`, `task`, `meeting`, `remind`
  final String action;
  final String type;
  final String title;
  final String? description;
  final String client;
  final String? purpose;
  final bool isStructured;
}

class ReminderContextParser {
  ReminderContextParser._();

  static final List<RegExp> _noiseTailPatterns = <RegExp>[
    RegExp(
      r'\b(reminder\s+laga(?:o|na)?\s*do?|reminder\s+lagao|reminder\s+set|'
      r'yaad\s*dila(?:o|na)?\s*do?)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'रिमाइंडर\s*लगा(?:ओ|ना)?\s*दो?|रिमाइंडर\s*लगा\s*दो|याद\s*दिला(?:ओ|ना)?\s*दो?',
      unicode: true,
    ),
  ];

  static const _purposeEndStop = {
    'hai',
    'hain',
    'ho',
    'tha',
    'the',
    'karna',
    'karo',
    'karni',
    'karne',
    'call',
    'phone',
    'reminder',
    'baje',
    'aaj',
    'kal',
    'parso',
    'ko',
    'dilana',
    'dilao',
    'lagao',
    'laga',
    'yaad',
    'dila',
  };

  static String _collectPaymentTitle(String client, String work) {
    final amt = extractInrAmountFromText(work);
    if (amt != null && amt > 0) {
      return 'Collect ₹${formatDisplayInrAmount(amt)} from $client';
    }
    return 'Collect from $client';
  }

  /// First user sentence, stripped of reminder boilerplate — never bare "Reminder".
  static String _firstMeaningfulTitle(String full) {
    var s = _stripForParsing(full).trim();
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    if (s.isEmpty) {
      return 'Task';
    }
    for (var segment in s.split(RegExp(r'(?<=[.!?])\s+'))) {
      var seg = segment.trim();
      if (seg.isEmpty) {
        continue;
      }
      seg = _stripOneSentenceLeadNoise(seg);
      seg = _stripReminderWordPrefix(seg);
      if (seg.isEmpty) {
        continue;
      }
      final firstWord = seg.split(RegExp(r'\s+')).first.toLowerCase();
      if (firstWord == 'reminder' && seg.length <= 9) {
        continue;
      }
      final words = seg
          .split(RegExp(r'\s+'))
          .where((e) => e.isNotEmpty)
          .take(16)
          .toList(growable: false);
      if (words.isEmpty) {
        continue;
      }
      if (words.length == 1 && words[0].toLowerCase() == 'reminder') {
        continue;
      }
      var title = _titleCase(words.join(' '));
      if (title.length > 100) {
        title = '${title.substring(0, 97)}…';
      }
      return title;
    }
    return _fallbackTitleWords(full);
  }

  static String _stripOneSentenceLeadNoise(String seg) {
    var o = seg.trim();
    o = o.replaceFirst(
      RegExp(
        r'^(reminder:?\s*|set\s+a\s+reminder,?\s*|remind\s+me\s+to\s*)\s*',
        caseSensitive: false,
      ),
      '',
    ).trim();
    return o;
  }

  static String _stripReminderWordPrefix(String seg) {
    var o = seg.trim();
    final low = o.toLowerCase();
    if (low == 'reminder') {
      return '';
    }
    if (low.startsWith('reminder ')) {
      o = o.substring(9).trim();
    }
    return o;
  }

  static String _fallbackTitleWords(String full) {
    var s = _stripForParsing(full).trim();
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    final words = s
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .take(6)
        .toList(growable: false);
    if (words.isEmpty) {
      return 'Task';
    }
    final t = _titleCase(words.join(' '));
    final low = t.toLowerCase();
    if (low == 'reminder' || (words.length == 1 && low == 'reminder')) {
      return 'Task';
    }
    return t;
  }

  static String _callTitleFromClientAndPurpose(
    String clientCap,
    String? purpose,
  ) {
    return 'Call $clientCap';
  }

  /// Parse user text into structured fields. Always returns a [ReminderNlpResult].
  /// On weak match, [title] is the first few words of input — never the generic "Reminder".
  static ReminderNlpResult parse(String rawInput) {
    final full = rawInput.trim();
    if (full.isEmpty) {
      return const ReminderNlpResult(
        action: 'remind',
        type: 'task',
        title: 'Task',
        isStructured: true,
      );
    }
    var work = _stripForParsing(full);

    // --- Call: "Name ko ... call / phone" (any words between ko and call)
    final koCallLoose = RegExp(
      r'\b([A-Za-z][A-Za-z0-9]*(?:\s+[A-Za-z][A-Za-z0-9]*)?)\s+'
      r'ko\s*(.*?)\b(call|phone)(?:\s+karna?)?(?:\s+hai)?\b',
      caseSensitive: false,
    ).firstMatch(work);
    if (koCallLoose != null) {
      var client = capitalizeWords((koCallLoose.group(1) ?? '').trim());
      if (client.isNotEmpty) {
        final purpose = _extractPurposeBeforeKeLiye(work);
        final desc = _purposeToDescription(purpose);
        return ReminderNlpResult(
          action: 'call',
          type: 'call',
          client: client,
          purpose: purpose,
          description: desc,
          title: _callTitleFromClientAndPurpose(client, purpose),
          isStructured: true,
        );
      }
    }

    // --- Tight: "Name ko call" (adjacent) — same as above for short lines
    final koCall = RegExp(
      r'\b([A-Za-z][A-Za-z0-9]*(?:\s+[A-Za-z][A-Za-z0-9]*)?)\s+'
      r'ko\s+(?:call|phone|phone\s+karna?|call\s+karna?)\b',
      caseSensitive: false,
    ).firstMatch(work);
    if (koCall != null) {
      var client = capitalizeWords((koCall.group(1) ?? '').trim());
      if (client.isNotEmpty) {
        final purpose = _extractPurposeBeforeKeLiye(work);
        final desc = _purposeToDescription(purpose);
        return ReminderNlpResult(
          action: 'call',
          type: 'call',
          client: client,
          purpose: purpose,
          description: desc,
          title: _callTitleFromClientAndPurpose(client, purpose),
          isStructured: true,
        );
      }
    }

    // English: "call Rahul" / "call client X"
    final enCall = RegExp(
      r'^\b(?:to\s+)?call\s+([A-Za-z][A-Za-z0-9 ]{0,40}?)(?=\s+(?:at|on|for|aaj|kal|baje|reminder|ke liye)|$)',
      caseSensitive: false,
    ).firstMatch(work);
    if (enCall != null) {
      var client = capitalizeWords((enCall.group(1) ?? '').trim());
      for (final noise in {
        'me',
        'us',
        'her',
        'him',
        'them',
        'client',
        'customer',
        'user',
        'to',
        'a',
        'the',
      }) {
        if (client.toLowerCase() == noise) {
          client = '';
        }
      }
      if (client.isNotEmpty) {
        final purpose = _extractPurposeBeforeKeLiye(work);
        final desc = _purposeToDescription(purpose);
        return ReminderNlpResult(
          action: 'call',
          type: 'call',
          client: client,
          purpose: purpose,
          description: desc,
          title: _callTitleFromClientAndPurpose(client, purpose),
          isStructured: true,
        );
      }
    }

    // Hinglish payment: "Name se … lena / vasool / payment …"
    final sePay = RegExp(
      r'\b([A-Za-z][A-Za-z0-9]*)\s+se\s+.+?\b'
      r'(?:lena|lene|lenaa?|vasool|vasuli|payment|collect|milna|milega|chuk)\b',
      caseSensitive: false,
    ).firstMatch(work);
    if (sePay != null) {
      var client = formatClientDisplayName((sePay.group(1) ?? '').trim());
      if (client.isNotEmpty) {
        final purpose = _extractPurposeBeforeKeLiye(work);
        final desc = _purposeToDescription(purpose) ??
            (purpose != null && purpose.isNotEmpty ? _titleCase(purpose) : null);
        return ReminderNlpResult(
          action: 'payment',
          type: 'payment',
          client: client,
          purpose: purpose,
          description: desc,
          title: _collectPaymentTitle(client, work),
          isStructured: true,
        );
      }
    }

    // Payment / collect: "collect from Name" or "payment from Name"
    final pay = RegExp(
      r'(?:\b(?:collect|collection|payment|receive|vasooli?|lenaa?|lana|lene|lene)\b\s+from\s+'
      r'|\bfrom\s+)([A-Za-z][A-Za-z0-9 ]{0,40}?)(?=\s+(?:aaj|kal|baje|reminder|at|on|for|due|₹|ke liye|before)|$)',
      caseSensitive: false,
    ).firstMatch(work);
    if (pay != null) {
      var client = formatClientDisplayName((pay.group(1) ?? '').trim());
      for (final noise in {
        'me',
        'us',
        'the',
        'a',
        'bank',
        'office',
        'home',
      }) {
        if (client.toLowerCase() == noise) {
          client = '';
        }
      }
      if (client.isNotEmpty) {
        final purpose = _extractPurposeBeforeKeLiye(work);
        final desc = _purposeToDescription(purpose) ??
            (purpose != null && purpose.isNotEmpty ? _titleCase(purpose) : null);
        return ReminderNlpResult(
          action: 'payment',
          type: 'payment',
          client: client,
          purpose: purpose,
          description: desc,
          title: _collectPaymentTitle(client, work),
          isStructured: true,
        );
      }
    }

    if (RegExp(
      r'\b(payment|collect|₹|rs\.?|rupees?)\b',
      caseSensitive: false,
    ).hasMatch(work)) {
      final amt = extractInrAmountFromText(work);
      return ReminderNlpResult(
        action: 'payment',
        type: 'payment',
        title: amt != null && amt > 0
            ? 'Collect ₹${formatDisplayInrAmount(amt)}'
            : _firstMeaningfulTitle(full),
        description: _trimDetail(full, max: 200),
        isStructured: true,
      );
    }

    // Fallback: first meaningful sentence (not "Reminder") + detail
    return ReminderNlpResult(
      action: 'remind',
      type: 'task',
      title: _firstMeaningfulTitle(full),
      description: _trimDetail(full, max: 500),
      isStructured: true,
    );
  }

  /// Re-parse [rawInput] when present; otherwise use stored [title] / [message]
  /// heuristics for legacy Firestore rows.
  static HydratedReminderDisplay hydrateForDisplay({
    required String title,
    required String description,
    required String message,
    required String type,
    required String client,
    String? rawInput,
  }) {
    final raw = (rawInput ?? '').trim();
    if (raw.isNotEmpty) {
      final p = ReminderContextParser.parse(raw);
      if (p.isStructured) {
        return HydratedReminderDisplay(
          title: capitalizeWords(p.title),
          description: (p.description ?? '').trim().isNotEmpty
              ? capitalizeWords(p.description!.trim())
              : '',
        );
      }
    }

    if (_looksLikeMessyUserSentence(
      title: title,
      message: message,
    )) {
      final p = ReminderContextParser.parse(message);
      if (p.isStructured) {
        return HydratedReminderDisplay(
          title: capitalizeWords(p.title),
          description: (p.description ?? description).trim().isNotEmpty
              ? capitalizeWords((p.description ?? description).trim())
              : '',
        );
      }
    }

    var t = title.trim();
    var d = description.trim();
    if (t.isEmpty || t.toLowerCase() == 'reminder') {
      t = _fallbackTitleWords(message);
      if (d.isEmpty) {
        d = _trimDetail(message, max: 200);
      }
    } else {
      d = d.isNotEmpty
          ? d
          : (message != title ? _trimDetail(message, max: 200) : '');
    }
    final outTitle = t.isNotEmpty ? capitalizeWords(t) : t;
    final outDesc = d.isNotEmpty ? capitalizeWords(d) : d;
    return HydratedReminderDisplay(title: outTitle, description: outDesc);
  }

  static bool _looksLikeMessyUserSentence({
    required String title,
    required String message,
  }) {
    final t = title.trim();
    if (t.length < 8) {
      return false;
    }
    if (t.length < 50 &&
        !RegExp(
          r'\b(ko|karna|karna hai|baje|aaj|laga|dila|ke liye)\b',
          caseSensitive: false,
        ).hasMatch(t)) {
      return false;
    }
    return RegExp(
      r'\b(ko|karna|karna hai|baje|aaj|laga|dila|ke liye|reminder|yaad)\b',
      caseSensitive: false,
    ).hasMatch(t);
  }

  static String _stripForParsing(String s) {
    var o = s.trim();
    o = o
        .replaceFirst(
          RegExp(
            r'^(please\s+|can you\s+|could you\s+|kindly\s+)?'
            r'(set(\s+a)?\s+reminder(\s+for|\s+to)?|reminder:)\s+',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    o = o
        .replaceFirst(
          RegExp(
            r'^(please\s+|can you\s+|could you\s+|kindly\s+)?'
            r'(remind(er)?(\s+me)?(\s+to)?)\s+',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    o = o.replaceAll(RegExp(r'\s+'), ' ');
    return o;
  }

  static String? _extractPurposeBeforeKeLiye(String work) {
    final lower = work.toLowerCase();
    // "k liye" Hinglish variant
    int i = lower.indexOf('ke liye');
    if (i < 0) {
      i = lower.indexOf('k liye');
    }
    if (i < 0) {
      return null;
    }
    var before = work.substring(0, i).trim();
    // Drop "… ko call karna hai …" so the client name is not picked as purpose.
    before = before
        .replaceFirst(
          RegExp(
            r'^.*?\bko\s*.*?\b(?:call|phone)(?:\s+karna)?(?:\s+hai)?\s*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    for (final p in _noiseTailPatterns) {
      before = p.removeFromString(before);
    }
    final words = before
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList(growable: false);
    if (words.isEmpty) {
      return null;
    }
    // Take 1–4 topic words from the end, skipping verb/noise tokens
    final take = <String>[];
    for (var j = words.length - 1; j >= 0 && take.length < 4; j--) {
      final word = words[j];
      final w = word.toLowerCase();
      if (_purposeEndStop.contains(w)) {
        continue;
      }
      if (RegExp(r'^\d+').hasMatch(w)) {
        break;
      }
      take.add(_stripEdgePunct(word));
    }
    if (take.isEmpty) {
      return null;
    }
    return take.reversed
        .where((e) => e.isNotEmpty)
        .join(' ')
        .trim();
  }

  static String _stripEdgePunct(String w) {
    return w
        .replaceFirst(RegExp(r'^[^a-zA-Z0-9\u0900-\u097F]+'), '')
        .replaceFirst(RegExp(r'[^a-zA-Z0-9\u0900-\u097F]+$'), '')
        .trim();
  }

  static String? _purposeToDescription(String? purpose) {
    if (purpose == null || purpose.trim().isEmpty) {
      return null;
    }
    return '${_titleCase(purpose)} discussion';
  }

  static String _titleCase(String phrase) {
    return phrase
        .split(RegExp(r'\s+'))
        .map(
          (w) => w.isEmpty
              ? w
              : w[0].toUpperCase() + w.substring(1).toLowerCase(),
        )
        .join(' ');
  }

  static String _trimDetail(String s, {int max = 200}) {
    var t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length > max) {
      t = '${t.substring(0, max - 1)}…';
    }
    return t;
  }
}

class HydratedReminderDisplay {
  const HydratedReminderDisplay({
    required this.title,
    this.description = '',
  });

  final String title;
  final String description;
}

extension _NlpReRemove on RegExp {
  String removeFromString(String s) {
    return s.replaceAll(this, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
