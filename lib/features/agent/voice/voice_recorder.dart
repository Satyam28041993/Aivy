import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// Records one spoken message from the mic and hands it back as a WAV.
///
/// It stops by itself once the user has spoken and then gone quiet, so a turn
/// is "tap, speak, done" — the second tap is there if they want it. Raw PCM is
/// streamed rather than written to a file, so the same code runs on the phone
/// and on the web with no temporary paths.
class VoiceRecorder {
  /// What Gemini hears best and what keeps a minute under ~2 MB.
  static const int sampleRate = 16000;

  /// Quiet for this long after speech ends the recording.
  static const Duration silenceToStop = Duration(milliseconds: 1600);

  /// Nothing said at all for this long → give up rather than wait forever.
  static const Duration noSpeechTimeout = Duration(seconds: 7);

  /// A hard ceiling; the server refuses much more than a minute.
  static const Duration maxLength = Duration(seconds: 55);

  /// RMS (0..1) above which a chunk counts as speech.
  static const double speechLevel = 0.035;

  AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final BytesBuilder _pcm = BytesBuilder(copy: false);
  Completer<Uint8List?>? _done;
  Timer? _ceiling;
  DateTime _startedAt = DateTime.now();
  DateTime? _lastSpeech;
  bool _heardSpeech = false;

  /// Live mic level for the composer's meter, 0..1.
  final ValueNotifier<double> level = ValueNotifier<double>(0);

  bool get isRecording => _done != null && !_done!.isCompleted;

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Starts listening. The returned future completes with the WAV once the
  /// user stops (or goes quiet), or null if nothing was said.
  Future<Uint8List?> record() async {
    if (isRecording) {
      return _done!.future;
    }
    if (!await _recorder.hasPermission()) {
      throw StateError('Microphone permission not granted');
    }
    // A fresh recorder per take: a reused one has been seen to keep the last
    // session's stream half-open on Android.
    try {
      await _recorder.dispose();
    } catch (_) {}
    _recorder = AudioRecorder();

    _pcm.clear();
    _heardSpeech = false;
    _lastSpeech = null;
    _startedAt = DateTime.now();
    final done = Completer<Uint8List?>();
    _done = done;

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        androidConfig: AndroidRecordConfig(
          audioSource: AndroidAudioSource.voiceCommunication,
        ),
      ),
    );
    _sub = stream.listen(_onChunk, onError: (Object e) {
      debugPrint('[Voice] recorder error: $e');
      unawaited(_finish(keep: false));
    });
    _ceiling = Timer(maxLength, () => unawaited(stop()));
    return done.future;
  }

  void _onChunk(Uint8List chunk) {
    if (chunk.isEmpty) {
      return;
    }
    _pcm.add(chunk);
    final rms = pcmLevel(chunk);
    level.value = math.min(1, rms * 6);
    final now = DateTime.now();
    if (rms >= speechLevel) {
      _heardSpeech = true;
      _lastSpeech = now;
    }
    if (_heardSpeech) {
      if (now.difference(_lastSpeech!) >= silenceToStop) {
        unawaited(stop());
      }
    } else if (now.difference(_startedAt) >= noSpeechTimeout) {
      unawaited(_finish(keep: false));
    }
  }

  /// Stops now and delivers what was said so far.
  Future<void> stop() => _finish(keep: true);

  /// Stops and throws the take away.
  Future<void> cancel() => _finish(keep: false);

  Future<void> _finish({required bool keep}) async {
    final done = _done;
    if (done == null || done.isCompleted) {
      return;
    }
    _ceiling?.cancel();
    try {
      await _recorder.stop();
    } catch (e) {
      debugPrint('[Voice] stop: $e');
    }
    await _sub?.cancel();
    _sub = null;
    level.value = 0;
    final pcm = _pcm.takeBytes();
    done.complete(keep && _heardSpeech && pcm.isNotEmpty ? wavFromPcm16(pcm, sampleRate) : null);
  }

  Future<void> dispose() async {
    await cancel();
    try {
      await _recorder.dispose();
    } catch (_) {}
    level.dispose();
  }
}

/// Root-mean-square of little-endian 16-bit samples, scaled to 0..1.
double pcmLevel(Uint8List chunk) {
  final data = ByteData.sublistView(chunk);
  final n = chunk.length ~/ 2;
  if (n == 0) {
    return 0;
  }
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final s = data.getInt16(i * 2, Endian.little) / 32768.0;
    sum += s * s;
  }
  return math.sqrt(sum / n);
}

/// Wraps raw mono 16-bit PCM in a WAV header.
Uint8List wavFromPcm16(Uint8List pcm, int sampleRate) {
  final header = ByteData(44);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  final out = BytesBuilder(copy: false)
    ..add(header.buffer.asUint8List())
    ..add(pcm);
  return out.takeBytes();
}
