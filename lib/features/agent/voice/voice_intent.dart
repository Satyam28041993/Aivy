/// Reading a short spoken answer to a card: "haan" confirms it, "nahi" drops it.
///
/// Only a *short* answer made of these words counts. "Haan, 10 din baad follow
/// up lagao" carries more than a yes, so it goes to Aivy as an ordinary turn.
enum VoiceAnswer { yes, no, other }

const _yesKeys = {
  'haan', 'haa', 'ha', 'han', 'hanji', 'yes', 'yeah', 'yep', 'ok', 'okay',
  'theek', 'thik', 'sahi', 'confirm', 'confirmed', 'bilkul', 'save', 'done', 'pakka',
};
const _yesFiller = {'hai', 'ji', 'kar', 'karo', 'kardo', 'do', 'de', 'dijiye', 'please', 'it', 'go', 'ahead', 'sure'};
const _noKeys = {'nahi', 'nahin', 'na', 'no', 'cancel', 'mat', 'rehne', 'chhodo', 'chodo', 'stop'};
const _noFiller = {'do', 'karo', 'kar', 'ji', 'hai', 'it', 'dijiye', 'please', 'abhi'};

VoiceAnswer readVoiceAnswer(String said) {
  final words = said
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty || words.length > 5) {
    return VoiceAnswer.other;
  }
  final hasNo = words.any(_noKeys.contains);
  if (hasNo && words.every((w) => _noKeys.contains(w) || _noFiller.contains(w))) {
    return VoiceAnswer.no;
  }
  final hasYes = words.any(_yesKeys.contains);
  if (!hasNo && hasYes && words.every((w) => _yesKeys.contains(w) || _yesFiller.contains(w))) {
    return VoiceAnswer.yes;
  }
  return VoiceAnswer.other;
}
