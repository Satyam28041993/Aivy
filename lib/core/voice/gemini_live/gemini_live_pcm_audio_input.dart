import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// Streams PCM16 mono mic audio for Gemini Live API input.
class GeminiLivePcmAudioInput {
  /// Gemini Live requires **16 kHz** input (its *output* is 24 kHz — the two
  /// are not the same, and recording at 24 kHz made every utterance arrive
  /// stretched, so the model heard nothing it could answer).
  static const int sampleRate = 16000;

  AudioRecorder _recorder = AudioRecorder();
  StreamController<Uint8List>? _audioDataController;
  StreamSubscription<Uint8List>? _recorderStreamSub;

  bool isRecording = false;

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> init() async {
    final ok = await _recorder.hasPermission();
    if (!ok) {
      throw StateError('Microphone permission not granted');
    }
  }

  Future<Stream<Uint8List>?> startRecordingStream() async {
    await _recorderStreamSub?.cancel();
    await _audioDataController?.close();

    _audioDataController = StreamController<Uint8List>.broadcast();

    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (e) {
      debugPrint('[GeminiLive] stop before restart: $e');
    }
    await _recorder.dispose();
    _recorder = AudioRecorder();

    final config = const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
      numChannels: 1,
      androidConfig: AndroidRecordConfig(
        audioSource: AndroidAudioSource.voiceCommunication,
      ),
    );

    final rawStream = await _recorder.startStream(config);
    _recorderStreamSub = rawStream.listen(
      (data) {
        if (data.isNotEmpty &&
            _audioDataController != null &&
            !_audioDataController!.isClosed) {
          _audioDataController!.add(data);
        }
      },
      onError: (Object e) {
        debugPrint('[GeminiLive] recorder stream error: $e');
        _audioDataController?.addError(e);
      },
    );

    isRecording = true;
    return _audioDataController!.stream;
  }

  Future<void> stopRecording() async {
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (e) {
      debugPrint('[GeminiLive] stop recorder: $e');
    }
    await _recorderStreamSub?.cancel();
    await _audioDataController?.close();
    _audioDataController = null;
    isRecording = false;
  }

  /// Mobile browsers often leave AudioContext suspended until resume().
  Future<void> resume() async {
    try {
      await _recorder.resume();
    } catch (e) {
      debugPrint('[GeminiLive] recorder resume: $e');
    }
  }

  Future<void> dispose() async {
    await stopRecording();
    await _recorder.dispose();
  }
}
