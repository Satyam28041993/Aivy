import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Plays 24 kHz PCM16 mono audio chunks from Gemini Live API output.
///
/// The native path uses `flutter_soloud`, which on the web requires
/// SharedArrayBuffer and therefore COOP/COEP response headers. Enabling those
/// would block every cross-origin resource the app loads (the Facebook SDK
/// among them), so on the web we drive an [web.AudioContext] directly.
///
/// Chunks arrive faster than real time, so each is scheduled back-to-back
/// against a running play head instead of played immediately — otherwise they
/// would overlap into noise.
class GeminiLivePcmAudioOutput {
  bool initialized = false;

  static const int sampleRate = 24000;

  web.AudioContext? _ctx;
  double _playHead = 0;
  final List<web.AudioBufferSourceNode> _scheduled = [];

  Future<void> init() async {
    if (initialized) {
      return;
    }
    _ctx = web.AudioContext();
    initialized = true;
  }

  Future<void> dispose() async {
    await stop();
    final ctx = _ctx;
    _ctx = null;
    initialized = false;
    if (ctx != null) {
      try {
        await ctx.close().toDart;
      } catch (_) {}
    }
  }

  Future<void> startPlayback() async {
    if (!initialized) {
      await init();
    }
    final ctx = _ctx;
    if (ctx == null) {
      return;
    }
    // Browsers hold the context suspended until a user gesture; the mic tap
    // that got us here counts as one.
    if (ctx.state == 'suspended') {
      try {
        await ctx.resume().toDart;
      } catch (_) {}
    }
    await stop();
    _playHead = ctx.currentTime;
  }

  void playChunk(Uint8List audioChunk) {
    final ctx = _ctx;
    if (ctx == null || audioChunk.lengthInBytes < 2) {
      return;
    }

    final frames = audioChunk.lengthInBytes ~/ 2;
    final pcm = ByteData.sublistView(audioChunk);
    final samples = Float32List(frames);
    for (var i = 0; i < frames; i++) {
      // PCM16 little-endian → normalised float in [-1, 1].
      samples[i] = pcm.getInt16(i * 2, Endian.little) / 32768.0;
    }

    final buffer = ctx.createBuffer(1, frames, sampleRate.toDouble());
    buffer.copyToChannel(samples.toJS, 0);

    final source = ctx.createBufferSource();
    source.buffer = buffer;
    source.connect(ctx.destination);

    final now = ctx.currentTime;
    // A gap means playback drained; restart the head from now so we never
    // schedule in the past (the browser would dump those chunks at once).
    if (_playHead < now) {
      _playHead = now;
    }
    source.start(_playHead);
    _playHead += frames / sampleRate;

    _scheduled.add(source);
    source.onended = ((web.Event _) => _scheduled.remove(source)).toJS;
  }

  Future<void> stop() async {
    for (final source in List<web.AudioBufferSourceNode>.of(_scheduled)) {
      try {
        source.stop();
      } catch (_) {}
    }
    _scheduled.clear();
    _playHead = _ctx?.currentTime ?? 0;
  }

  /// No-op on the web: chunks are already scheduled, so the tail plays out.
  Future<void> finishStream() async {}
}
