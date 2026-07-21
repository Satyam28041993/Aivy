import '../../../core/voice/google_voice_service.dart';
import '../../../core/voice/voice_feature_settings.dart';
import '../models/aivy_ai_response.dart';
import '../utils/aivy_response_formatter.dart';

/// Runs Google Cloud TTS before persisting the assistant bubble when enabled.
class AssistantGoogleVoiceCompletion {
  const AssistantGoogleVoiceCompletion._();

  static Future<String?> maybeSynthesizeTtsUrl({
    required GoogleVoiceService? voice,
    required AivyAiResponse response,
  }) async {
    if (voice == null) {
      return null;
    }
    if (!await VoiceFeatureSettings.assistantVoiceRepliesEnabled) {
      return null;
    }
    final text = userReplyOnlyForChat(response).trim();
    if (text.length < 2) {
      return null;
    }
    return voice.synthesizeToStorage(text);
  }
}
