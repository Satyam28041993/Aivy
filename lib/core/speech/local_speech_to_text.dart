import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Dictation using the platform recognizer. Engine choice (on-device vs cloud)
/// is left to the OS when [SpeechListenOptions.onDevice] is false.
class LocalSpeechToText {
  LocalSpeechToText() : _speech = SpeechToText();

  final SpeechToText _speech;
  bool _didInit = false;

  bool get isAvailable => _speech.isAvailable;
  bool get isListening => _speech.isListening;

  void _onSpeechError(SpeechRecognitionError e) {
    // Examples: "error_no_match", "error_speech_timeout", "error_network", etc.
    debugPrint(
      '[LocalSpeechToText] errorMsg="${e.errorMsg}" permanent=${e.permanent} '
      '($e)',
    );
  }

  /// Initializes the platform speech service. Safe to call once; subsequent
  /// calls return the cached availability flag.
  Future<bool> initialize() async {
    if (_didInit) {
      return _speech.isAvailable;
    }
    _didInit = true;
    return _speech.initialize(onError: _onSpeechError);
  }

  /// Starts streaming partial results. Call [stop] to end the session.
  ///
  /// [hapticOnStart]: use false when immediately restarting after a platform
  /// timeout so only the first segment triggers feedback.
  Future<void> listen({
    required void Function(String text) onText,
    bool hapticOnStart = true,
  }) async {
    if (!_didInit) {
      await initialize();
    }
    if (!_speech.isAvailable) {
      return;
    }
    if (hapticOnStart) {
      await HapticFeedback.lightImpact();
    }
    await _speech.listen(
      onResult: (result) => onText(result.recognizedWords),
      listenFor: const Duration(minutes: 5),
      pauseFor: const Duration(seconds: 10),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        onDevice: false,
        listenMode: ListenMode.dictation,
      ),
    );
  }

  Future<void> stop() async {
    if (_speech.isListening) {
      await _speech.stop();
    }
  }
}
