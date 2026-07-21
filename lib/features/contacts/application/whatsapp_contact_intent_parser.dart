import '../../whatsapp/utils/whatsapp_outbound_text.dart';

/// Parses chat lines that trigger “send WhatsApp to contact” from [ControlledChatFlow].
///
/// **Recommended format (Hindi / Hinglish):**
/// `{Name} ko WhatsApp pe massege bhejo ki {actual WhatsApp text}`
///
/// - `{Name}` — jisko bhejna hai (Contacts jaisa naam; optional `Hindi -` hata diya jata hai).
/// - `ki` / `ke` / Hindi **कि** ke **baad** jo bhi likho, wahi WhatsApp par jata hai.
/// - `message` / `msg` bhi `massege` ki jagah chal sakta hai; `par` = `pe`.
/// - `bhejo` ya **`karo`** dono: `… pe massege karo ki …`.
class WhatsappContactIntent {
  const WhatsappContactIntent({
    required this.contactNameToken,
    this.messageTail,
  });

  final String contactNameToken;
  final String? messageTail;
}

class WhatsappContactIntentParser {
  /// Must run **before** [_koWhatsapp], otherwise "… ko WhatsApp" matches too early
  /// and `pe massege bhejo ki …` wrongly becomes the whole message body.
  ///
  /// Examples:
  /// - `Satyam ko WhatsApp pe massege bhejo ki sir artwork pending hai`
  /// - `Hindi - Rajesh (PGPL) ko WhatsApp pe message bhejo ki Payment due reminder`
  static final RegExp _koWhatsappPeBhejoKi = RegExp(
    r'^(.+?)\s+ko\s+(?:whatsapp|व्हाट्सएप|व्हाट्सऐप|व्हाट्सप्प)\s+(?:pe|par)\s+'
    r'(?:'
    r'(?:massege|message|msg)\s+(?:bhejo|karo)\s+|'
    r'(?:bhejo|karo)\s+'
    r')'
    r'(?:ki|ke|\u0915\u093f)\s+(.+)$',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _koWhatsapp = RegExp(
    r'''^(.+?)\s+ko\s+(whatsapp|व्हाट्सएप|व्हाट्सऐप|व्हाट्सप्प)\b''',
    caseSensitive: false,
  );

  static final RegExp _whatsappTo = RegExp(
    r'''^(whatsapp|व्हाट्सएप|व्हाट्सऐप|व्हाट्सप्प)\s+(?:pe\s+|par\s+|to\s+)?(.+)$''',
    caseSensitive: false,
  );

  static bool looksLikeWhatsappSendIntent(String raw) {
    final t = raw.trim().toLowerCase();
    if (t.isEmpty) {
      return false;
    }
    if (t.contains('whatsapp') ||
        t.contains('व्हाट्सएप') ||
        t.contains('व्हाट्सऐप') ||
        t.contains('व्हाट्सप्प')) {
      return true;
    }
    return _looksLikeCasualContactOutbound(t);
  }

  /// "Satyam ko hi bhejo" / "… massege bhejo" (no explicit WhatsApp word).
  static bool _looksLikeCasualContactOutbound(String low) {
    if (_containsStructuredBusinessKeywords(low)) {
      return false;
    }
    if (!low.contains(' ko ')) {
      return false;
    }
    if (low.contains('whatsapp') ||
        low.contains('wa pe') ||
        low.contains('व्हाट्स')) {
      return true;
    }
    if (RegExp(r'\s+ko\s+.*\b(hi|hello|hey|namaste)\b').hasMatch(low)) {
      return true;
    }
    if (low.contains('massege') || low.contains('message')) {
      return true;
    }
    return false;
  }

  static bool _containsStructuredBusinessKeywords(String low) {
    const keys = [
      'payment',
      'due',
      'reminder',
      'invoice',
      'quotation',
      'quote',
      'order',
      'dispatch',
      'meeting',
      'task',
      'receive',
      'paid',
      'pgpl',
      'milega',
      'mail',
      'gmail',
      'email',
      'bank',
      'upi',
      'ledger',
      'quot',
    ];
    for (final k in keys) {
      if (low.contains(k)) {
        return true;
      }
    }
    return false;
  }

  /// Returns null when this is not a contact-targeted WhatsApp send intent.
  static WhatsappContactIntent? tryParse(String raw) {
    final t = raw.trim();
    if (t.isEmpty) {
      return null;
    }
    final ki = _tryWhatsappPeBhejoKi(t);
    if (ki != null) {
      return ki;
    }
    final m1 = _koWhatsapp.firstMatch(t);
    if (m1 != null) {
      final name = _cleanName(m1.group(1) ?? '');
      if (name.isEmpty) {
        return null;
      }
      final rest = t.substring(m1.end).trim();
      final tail = _extractMessageTail(rest);
      return WhatsappContactIntent(contactNameToken: name, messageTail: tail);
    }
    final m2 = _whatsappTo.firstMatch(t);
    if (m2 != null) {
      final rest = (m2.group(2) ?? '').trim();
      if (rest.isEmpty) {
        return null;
      }
      final parts = rest.split(RegExp(r'\s+'));
      if (parts.isEmpty) {
        return null;
      }
      final name = _cleanName(parts.first);
      if (name.isEmpty) {
        return null;
      }
      final tail = parts.length > 1
          ? rest.substring(parts.first.length).trim()
          : null;
      return WhatsappContactIntent(
        contactNameToken: name,
        messageTail: (tail != null && tail.isNotEmpty) ? tail : null,
      );
    }
    return _tryCasualKoWhatsappSend(t);
  }

  static WhatsappContactIntent? _tryWhatsappPeBhejoKi(String t) {
    var s = t.trim();
    s = s.replaceFirst(RegExp(r'^aivy\s+', caseSensitive: false), '').trim();
    final m = _koWhatsappPeBhejoKi.firstMatch(s);
    if (m == null) {
      return null;
    }
    final name = _cleanNameForLookup(m.group(1) ?? '');
    final body = (m.group(2) ?? '').trim();
    if (name.isEmpty || body.isEmpty) {
      return null;
    }
    return WhatsappContactIntent(
      contactNameToken: name,
      messageTail: WhatsappOutboundText.normalize(body),
    );
  }

  /// Strips optional `Hindi -` and instructional `(…)` from the name token.
  static String _cleanNameForLookup(String raw) {
    var x = _cleanName(raw);
    x = x.replaceFirst(RegExp(r'^hindi\s*[-–—]\s*', caseSensitive: false), '').trim();
    x = _cleanName(x);
    final lp = x.indexOf('(');
    final rp = x.indexOf(')');
    if (lp > 0 && rp > lp) {
      final inner = x.substring(lp + 1, rp).toLowerCase();
      if (RegExp(
        r'jisko|bhejna|whatsapp|contact|client',
        caseSensitive: false,
      ).hasMatch(inner)) {
        final before = x.substring(0, lp).trim();
        if (before.isNotEmpty) {
          x = before;
        }
      }
    }
    return x.trim();
  }

  /// "Aivy satyam ko hi bhejo" style lines (after [m1]/[m2] miss).
  static WhatsappContactIntent? _tryCasualKoWhatsappSend(String raw) {
    var t = raw.trim();
    if (t.isEmpty) {
      return null;
    }
    t = t.replaceFirst(RegExp(r'^aivy\s+', caseSensitive: false), '').trim();
    final low = t.toLowerCase();
    if (_containsStructuredBusinessKeywords(low)) {
      return null;
    }
    final koIdx = low.indexOf(' ko ');
    if (koIdx < 0) {
      return null;
    }
    final name = _cleanName(t.substring(0, koIdx));
    final tail = t.substring(koIdx + 4).trim();
    if (name.isEmpty || tail.isEmpty) {
      return null;
    }
    final tailLow = tail.toLowerCase();
    final explicit = low.contains('whatsapp') ||
        tailLow.contains('whatsapp') ||
        low.contains('wa pe') ||
        tailLow.contains('wa pe');
    final mistypeMsg =
        tailLow.contains('massege') || tailLow.contains('message');
    final greeting = RegExp(
      r'^(hi|hello|hey|namaste)\b',
      caseSensitive: false,
    ).hasMatch(tailLow) ||
        (RegExp(r'\b(hi|hello|hey)\b', caseSensitive: false).hasMatch(tailLow) &&
            tail.length <= 56);
    if (!explicit && !greeting && !mistypeMsg) {
      return null;
    }
    final msg = _shortenCasualMessageBody(tail);
    if (msg == null || msg.trim().isEmpty) {
      return null;
    }
    return WhatsappContactIntent(
      contactNameToken: name,
      messageTail: msg.trim(),
    );
  }

  static String? _shortenCasualMessageBody(String tail) {
    final gm = RegExp(
      r'^(hi|hello|hey|namaste)\b',
      caseSensitive: false,
    ).firstMatch(tail);
    if (gm != null) {
      final word = gm.group(0)!;
      final cap = word.substring(0, 1).toUpperCase() +
          (word.length > 1 ? word.substring(1).toLowerCase() : '');
      final after = tail.substring(word.length).trim().toLowerCase();
      if (after.isEmpty ||
          after.startsWith('massege') ||
          after.startsWith('message') ||
          after.startsWith('bhejo') ||
          after.startsWith('bhej')) {
        return cap;
      }
    }
    return tail.trim().isEmpty ? null : tail.trim();
  }

  static String _cleanName(String s) {
    var x = s.trim();
    for (final noise in ['"', "'", '“', '”', '‘', '’']) {
      x = x.replaceAll(noise, '');
    }
    return x.trim();
  }

  static String? _extractMessageTail(String afterVerb) {
    if (afterVerb.isEmpty) {
      return null;
    }
    final low = afterVerb.toLowerCase();
    for (final prefix in [
      'karo',
      'kar do',
      'kardo',
      'bhejo',
      'bhej do',
      'bhejdo',
      'send',
      'message',
      'likho',
      'lagao',
      'lagwa',
      'lagwa do',
    ]) {
      if (low.startsWith(prefix)) {
        final tail = afterVerb.substring(prefix.length).trim();
        return tail.isEmpty ? null : tail;
      }
    }
    if (RegExp(r'^[,\s]+').hasMatch(afterVerb)) {
      return afterVerb.replaceFirst(RegExp(r'^[,\s]+'), '').trim().isEmpty
          ? null
          : afterVerb.replaceFirst(RegExp(r'^[,\s]+'), '').trim();
    }
    return afterVerb.trim().isEmpty ? null : afterVerb.trim();
  }
}
