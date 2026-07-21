/// Parsed send-mail intent from a single chat line.
class GoogleGmailSendIntent {
  const GoogleGmailSendIntent({
    required this.to,
    required this.subject,
    required this.body,
  });

  final String to;
  final String subject;
  final String body;
}

class GoogleGmailIntentParser {
  GoogleGmailIntentParser._();

  static final RegExp _email = RegExp(
    r'[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}',
    caseSensitive: false,
  );

  static final RegExp _verb = RegExp(
    r'\b(mail|email|gmail|send|भेजो|मेल|ईमेल)\b',
    caseSensitive: false,
  );

  static final RegExp _subjectTag = RegExp(
    r'\bsubject\s*[:\-]\s*([^\n]+?)(?=\s+body\s*[:\-]|$)',
    caseSensitive: false,
  );

  static final RegExp _bodyTag = RegExp(
    r'\bbody\s*[:\-]\s*(.+)$',
    caseSensitive: false,
  );

  static bool looksLike(String t) {
    final s = t.trim();
    if (s.length < 12) {
      return false;
    }
    return _verb.hasMatch(s) && _email.hasMatch(s);
  }

  static GoogleGmailSendIntent? tryParse(String raw) {
    if (!looksLike(raw)) {
      return null;
    }
    final m = _email.firstMatch(raw);
    if (m == null) {
      return null;
    }
    final to = m.group(0)!.trim();

    var subject = 'Aivy';
    final sm = _subjectTag.firstMatch(raw);
    if (sm != null && sm.group(1) != null) {
      subject = sm.group(1)!.trim();
      if (subject.length > 200) {
        subject = subject.substring(0, 200);
      }
    }

    var body = '';
    final bm = _bodyTag.firstMatch(raw);
    if (bm != null && bm.group(1) != null) {
      body = bm.group(1)!.trim();
    } else {
      var rest = raw.replaceFirst(m.group(0)!, ' ');
      rest = rest.replaceAll(_verb, ' ');
      rest = rest.replaceAll(_subjectTag, ' ');
      rest = rest.replaceAll(RegExp(r'\s+'), ' ').trim();
      body = rest.isEmpty ? '—' : rest;
    }
    if (body.length > 8000) {
      body = body.substring(0, 8000);
    }
    return GoogleGmailSendIntent(to: to, subject: subject, body: body);
  }
}
