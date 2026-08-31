library;

/// Client-side mirror of `functions/src/projects/detect.ts`.
/// Dumps and status questions go to the cloud extract/query path.

final _paymentCue = RegExp(
  r'\b(payment|pay|invoice|inr|₹|rs\.?|rupees?|lena hai|collect|received|due amount)\b',
  caseSensitive: false,
);
final _itemKindCue = RegExp(
  r'\b(sample|samples|label|labels|approval|approve|rate|rates|qc|q\.c\.|po\b|p\.o\.|purchase order|follow[\s-]?up|meeting|mulakat|mulaqat|visit|dikha(?:ya|ye|o)?|pasand)\b',
  caseSensitive: false,
);
final _projectWord = RegExp(
  r'\b(project|proj|site|kaam)\b',
  caseSensitive: false,
);
final _waitingCue = RegExp(
  r'\b(waiting|unpe|un par|unka|unse|unki|unke|atka|atki|pending unpe|approval pending|rate pending)\b',
  caseSensitive: false,
);
final _queryCue = RegExp(
  r'\b(kya haal|kya hal|kya atka|kya atki|status|haal hai|kitna pending|kya pending|waiting on|project mein kya|project ka kya)\b',
  caseSensitive: false,
);
final _todayCue = RegExp(
  r'\b(aaj (ke )?(project|items?|kaam)|today.?s? (project|items?)|aaj kya (pending|atka))\b',
  caseSensitive: false,
);
final _simpleReminder = RegExp(
  r'^(?:[\w.]+ ){0,6}(ko )?(aaj|kal|parso|tomorrow|today).{0,40}\b(call|phone|milna|yaad|remind)',
  caseSensitive: false,
);

int _cueCount(String text, RegExp re) => re.allMatches(text).length;

bool looksLikeProjectDump(String text) {
  final t = text.trim();
  if (t.length < 18) {
    return false;
  }
  if (_paymentCue.hasMatch(t) && RegExp(r'\d').hasMatch(t)) {
    return false;
  }
  if (t.length <= 90 &&
      _simpleReminder.hasMatch(t) &&
      !(_itemKindCue.hasMatch(t) && _cueCount(t, _itemKindCue) >= 2) &&
      !_projectWord.hasMatch(t)) {
    return false;
  }
  if (_queryCue.hasMatch(t) || _todayCue.hasMatch(t)) {
    return false;
  }
  final kinds = _cueCount(t, _itemKindCue);
  if (_projectWord.hasMatch(t) &&
      (kinds >= 1 || _waitingCue.hasMatch(t) || t.length > 40)) {
    return true;
  }
  if (kinds >= 2) {
    return true;
  }
  if (kinds >= 1 && _waitingCue.hasMatch(t) && t.length >= 28) {
    return true;
  }
  final clauses = t
      .split(RegExp(r'\s*(?:,| aur | and )\s*', caseSensitive: false))
      .where((c) => c.trim().length > 8)
      .length;
  return kinds >= 1 && clauses >= 3;
}

bool looksLikeProjectQuery(String text) {
  final t = text.trim();
  if (t.isEmpty) {
    return false;
  }
  if (_paymentCue.hasMatch(t) && RegExp(r'\d').hasMatch(t)) {
    return false;
  }
  if (_todayCue.hasMatch(t) || _queryCue.hasMatch(t)) {
    return true;
  }
  return _projectWord.hasMatch(t) &&
      RegExp(
        r'\b(kya|haal|status|pending|atka|batao|dikhao)\b',
        caseSensitive: false,
      ).hasMatch(t);
}

bool looksLikeProjectTurn(String text) =>
    looksLikeProjectDump(text) || looksLikeProjectQuery(text);
