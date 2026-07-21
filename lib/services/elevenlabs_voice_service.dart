import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../core/voice/aivy_home_voice_service.dart';

/// Plays ElevenLabs TTS via Cloud Function `elevenLabsTts` (API key stays server-side).
class ElevenLabsVoiceService implements AivyHomeVoiceService {
  ElevenLabsVoiceService({
    FirebaseFunctions? functions,
    AudioPlayer? player,
  }) : _functions =
           functions ?? FirebaseFunctions.instanceFor(region: 'us-central1'),
       _player = player ?? AudioPlayer(),
       _ownsPlayer = player == null;

  final FirebaseFunctions _functions;
  final AudioPlayer _player;
  final bool _ownsPlayer;

  @override
  Stream<void> get onPlayerComplete => _player.onPlayerComplete;

  /// [text] empty → server uses default Hindi greeting.
  @override
  Future<void> speak({String? text, String? audioUrl}) async {
    if (audioUrl != null && audioUrl.trim().isNotEmpty) {
      // Home voice uses Google TTS URLs; ElevenLabs path is text-only.
    }
    final callable = _functions.httpsCallable('elevenLabsTts');
    final payload = <String, dynamic>{};
    final t = text?.trim();
    if (t != null && t.isNotEmpty) {
      payload['text'] = t;
    }
    final res = await callable.call(payload);
    final data = res.data;
    if (data == null) {
      throw StateError('No data from elevenLabsTts');
    }
    final map = Map<String, dynamic>.from(data);
    final b64 = '${map['audioBase64'] ?? ''}'.trim();
    if (b64.isEmpty) {
      throw StateError('Empty audio from server');
    }
    final bytes = base64Decode(b64);
    await _player.stop();
    await _player.setReleaseMode(ReleaseMode.release);
    await _player.setVolume(1.0);
    if (kIsWeb) {
      final uri = Uri.parse('data:audio/mpeg;base64,$b64');
      await _player.play(UrlSource(uri.toString()));
    } else {
      await _player.play(BytesSource(bytes));
    }
  }

  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() async {
    await _player.stop();
    if (_ownsPlayer) {
      await _player.dispose();
    }
  }
}
