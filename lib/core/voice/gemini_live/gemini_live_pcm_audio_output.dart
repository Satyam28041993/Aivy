import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

/// Plays 24 kHz PCM16 mono audio chunks from Gemini Live API output.
class GeminiLivePcmAudioOutput {
  bool initialized = false;
  AudioSource? _stream;
  SoundHandle? _handle;

  static const int sampleRate = 24000;

  Future<void> init() async {
    if (initialized) {
      return;
    }
    await SoLoud.instance.init(
      sampleRate: sampleRate,
      channels: Channels.mono,
    );
    initialized = true;
  }

  Future<void> dispose() async {
    await stop();
    if (initialized) {
      await SoLoud.instance.disposeAllSources();
      SoLoud.instance.deinit();
      initialized = false;
    }
  }

  Future<void> startPlayback() async {
    if (!SoLoud.instance.isInitialized) {
      await init();
    }
    await stop();
    _stream = SoLoud.instance.setBufferStream(
      bufferingType: BufferingType.released,
      bufferingTimeNeeds: 0,
      sampleRate: sampleRate,
      channels: Channels.mono,
      format: BufferType.s16le,
    );
    _handle = SoLoud.instance.play(_stream!);
  }

  void playChunk(Uint8List audioChunk) {
    final stream = _stream;
    if (stream != null && SoLoud.instance.isInitialized) {
      SoLoud.instance.addAudioDataStream(stream, audioChunk);
    }
  }

  Future<void> stop() async {
    final stream = _stream;
    final handle = _handle;
    if (stream != null && handle != null &&
        SoLoud.instance.getIsValidVoiceHandle(handle)) {
      SoLoud.instance.setDataIsEnded(stream);
      await SoLoud.instance.stop(handle);
    }
    _stream = null;
    _handle = null;
  }

  Future<void> finishStream() async {
    final stream = _stream;
    if (stream != null) {
      SoLoud.instance.setDataIsEnded(stream);
    }
  }
}
