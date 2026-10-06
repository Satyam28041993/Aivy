import 'package:aivy/features/agent/voice/voice_intent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a short yes confirms the card', () {
    for (final s in ['Haan', 'haan ji', 'ok', 'theek hai', 'haan save kar do', 'Yes, confirm.', 'bilkul']) {
      expect(readVoiceAnswer(s), VoiceAnswer.yes, reason: s);
    }
  });

  test('a short no drops it', () {
    for (final s in ['nahi', 'cancel karo', 'rehne do', 'no', 'mat karo']) {
      expect(readVoiceAnswer(s), VoiceAnswer.no, reason: s);
    }
  });

  test('a yes that carries more goes to Aivy as a turn', () {
    for (final s in ['haan 10 din baad follow up lagao', 'haan kal 11 baje', 'Bajaj ka visit', '']) {
      expect(readVoiceAnswer(s), VoiceAnswer.other, reason: s);
    }
  });
}
