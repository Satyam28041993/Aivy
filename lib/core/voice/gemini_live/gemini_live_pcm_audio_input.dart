import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// Streams 24 kHz PCM16 mono mic audio for Gemini Live API input.
class GeminiLivePcmAudioInput {
  AudioRecorder _recorder = AudioRecorder();
  StreamController<Uint8List>? _audioDataController;
  StreamSubscription<Uint8List>? _recorderStreamSub;
  StreamController<Amplitude>? _amplitudeController;
  StreamSubscription<Amplitude>? _amplitudeSubscription;

  bool isRecording = false;

  Stream<Amplitude>? get amplitudeStream => _amplitudeController?.stream;

  Future<void> init() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      throw StateError('Microphone permission not granted');
    }
  }

  Future<Stream<Uint8List>?> startRecordingStream() async {
    await _amplitudeSubscription?.cancel();
    await _amplitudeController?.close();
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
      sampleRate: 24000,
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

    _amplitudeController = StreamController<Amplitude>.broadcast();
    _amplitudeSubscription = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 100))
        .listen(_amplitudeController!.add);

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
    await _amplitudeSubscription?.cancel();
    await _amplitudeController?.close();
    _amplitudeController = null;
    await _recorderStreamSub?.cancel();
    await _audioDataController?.close();
    _audioDataController = null;
    isRecording = false;
  }

  Future<void> dispose() async {
    await stopRecording();
    await _recorder.dispose();
  }
}
