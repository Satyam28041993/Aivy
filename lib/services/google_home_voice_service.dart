import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import '../core/voice/aivy_home_voice_service.dart';
import '../core/voice/google_voice_service.dart';

/// Home “tap to hear Aivy” using **Google Cloud TTS** (`googleSpeechSynthesize`),
/// same backend voice family as chat assistant replies (hi-IN Neural2 female).
///
/// Uses [just_audio] (ExoPlayer on Android) for URL playback — aligned with
/// [AivyChatVoiceCoordinator] and chat bubble voice messages.
class GoogleHomeVoiceService implements AivyHomeVoiceService {
  GoogleHomeVoiceService({
    GoogleVoiceService? googleVoice,
    AudioPlayer? player,
  }) : _voice = googleVoice ?? GoogleVoiceService(),
       _player = player ?? AudioPlayer(),
       _ownsPlayer = player == null {
    _completeSub = _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _completeCtl.add(null);
      }
    });
  }

  final GoogleVoiceService _voice;
  final AudioPlayer _player;
  final bool _ownsPlayer;
  final StreamController<void> _completeCtl = StreamController<void>.broadcast();
  StreamSubscription<ProcessingState>? _completeSub;

  @override
  Stream<void> get onPlayerComplete => _completeCtl.stream;

  /// Default Hindi greeting when [text] is null or empty.
  static const String defaultGreeting =
      'नमस्ते, मैं ऐवी हूँ। आज मैं आपके बिज़नेस में मदद के लिए तैयार हूँ।';

  Future<void> _preparePlaybackSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
      await session.setActive(true);
    } catch (_) {}
  }

  /// Synthesizes via Cloud Function and plays the returned Storage MP3 URL.
  @override
  Future<void> speak({String? text, String? audioUrl}) async {
    await _preparePlaybackSession();
    await _player.stop();
    await _player.setVolume(1.0);
    final pre = audioUrl?.trim();
    if (pre != null && pre.isNotEmpty) {
      await _player.setUrl(pre);
      await _player.play();
      return;
    }
    final t =
        (text != null && text.trim().isNotEmpty) ? text.trim() : defaultGreeting;
    final url = await _voice.synthesizeToStorage(t);
    if (url == null || url.trim().isEmpty) {
      throw StateError('Google TTS returned no audio URL');
    }
    await _player.setUrl(url.trim());
    await _player.play();
  }

  /// Waits until playback actually finishes, then releases the player for mic capture.
  Future<void> speakAndWait({String? text, String? audioUrl}) async {
    await speak(text: text, audioUrl: audioUrl);
    try {
      var heardPlay = false;
      await _player.playerStateStream
          .firstWhere((s) {
            if (s.playing) {
              heardPlay = true;
            }
            return heardPlay &&
                !s.playing &&
                s.processingState == ProcessingState.completed;
          })
          .timeout(const Duration(seconds: 90));
    } on TimeoutException {
      // Best-effort stop if playback stalled.
    } finally {
      try {
        await _player.stop();
      } catch (_) {}
    }
  }

  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() async {
    await _completeSub?.cancel();
    await _player.stop();
    if (_ownsPlayer) {
      await _player.dispose();
    }
    await _completeCtl.close();
  }
}
