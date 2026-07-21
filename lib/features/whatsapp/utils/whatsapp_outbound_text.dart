/// Normalises text before sending via WhatsApp Cloud API (chat / CRM).
class WhatsappOutboundText {
  WhatsappOutboundText._();

  /// Trims and removes a redundant leading **ki / ke / कि** when users paste
  /// `ki aapka…` instead of only the clause after `… bhejo ki …`.
  static String normalize(String raw) {
    return stripRedundantLeadingKi(raw.trim()).trim();
  }

  static String stripRedundantLeadingKi(String s) {
    var t = s.trim();
    if (t.isEmpty) {
      return t;
    }
    var low = t.toLowerCase();
    if (low.startsWith('ki ')) {
      t = t.substring(3).trim();
      low = t.toLowerCase();
    } else if (low.startsWith('ke ')) {
      t = t.substring(3).trim();
      low = t.toLowerCase();
    } else if (t.startsWith(_kiDev)) {
      t = t.substring(_kiDev.length).trim();
      low = t.toLowerCase();
    }
    return t;
  }

  /// Hindi "ki" (कि) as UTF-8 grapheme often typed wrongly alone.
  static const String _kiDev = '\u0915\u093f';
}
