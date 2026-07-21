import 'package:just_audio/just_audio.dart';

/// Single shared player for assistant TTS so new playback stops the previous
/// (voice interruption) and mic / hands-free flows can call [stop].
class AivyChatVoiceCoordinator {
  AivyChatVoiceCoordinator._();
  static final AivyChatVoiceCoordinator instance = AivyChatVoiceCoordinator._();

  final AudioPlayer _player = AudioPlayer();

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> playUrl(String url) async {
    final u = url.trim();
    if (u.isEmpty) {
      return;
    }
    await stop();
    await _player.setUrl(u);
    await _player.play();
  }

  bool get isPlaying => _player.playing;
}
