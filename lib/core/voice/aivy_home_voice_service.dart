/// Contract for the home “mic tap” TTS player (Google Cloud TTS or ElevenLabs).
///
/// Shared typing avoids hot-reload / state mismatches when implementations swap.
abstract interface class AivyHomeVoiceService {
  Stream<void> get onPlayerComplete;

  /// [audioUrl] skips client TTS when the server already synthesized speech.
  Future<void> speak({String? text, String? audioUrl});

  Future<void> dispose();
}
