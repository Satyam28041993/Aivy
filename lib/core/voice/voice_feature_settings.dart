import 'package:shared_preferences/shared_preferences.dart';

/// Persisted toggles for Google Cloud voice behaviour (assistant TTS, autoplay).
class VoiceFeatureSettings {
  static const _kAssistantVoice = 'aivy_assistant_voice_replies';
  static const _kAutoPlay = 'aivy_auto_play_assistant_voice';

  static Future<bool> get assistantVoiceRepliesEnabled async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kAssistantVoice) ?? true;
  }

  static Future<void> setAssistantVoiceRepliesEnabled(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kAssistantVoice, value);
  }

  static Future<bool> get autoPlayAssistantVoice async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kAutoPlay) ?? true;
  }

  static Future<void> setAutoPlayAssistantVoice(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kAutoPlay, value);
  }
}
