import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/firebase/firebase_session.dart';

/// Talks to `aivyTranscribe` and `aivySpeak`, and plays what comes back.
///
/// Voice is a way into and out of the ordinary Aivy turn, nothing more — the
/// words heard are sent exactly as if they had been typed.
class VoiceService {
  VoiceService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseSession.functions;

  final FirebaseFunctions _functions;
  final AudioPlayer _player = AudioPlayer();
  int _take = 0;

  /// True while a reply is being played, for the stop button.
  final ValueNotifier<bool> speaking = ValueNotifier<bool>(false);

  /// What was said, in Roman Hinglish. Empty when nothing intelligible was heard.
  Future<String> transcribe(Uint8List wav) async {
    final callable = _functions.httpsCallable(
      'aivyTranscribe',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
    );
    final res = await callable.call<Map<String, dynamic>>(<String, dynamic>{
      'audioBase64': base64Encode(wav),
      'mimeType': 'audio/wav',
    });
    return (res.data['text'] as String? ?? '').trim();
  }

  /// Says [text] out loud. Returns when playback starts; a failure is quiet —
  /// the reply is already on screen.
  Future<void> speak(String text) async {
    final words = text.trim();
    if (words.isEmpty) {
      return;
    }
    final take = ++_take;
    try {
      final callable = _functions.httpsCallable(
        'aivySpeak',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
      );
      final res = await callable.call<Map<String, dynamic>>(<String, dynamic>{'text': words});
      // Something newer was asked for (or stop was pressed) while this was
      // being made: do not talk over it.
      if (take != _take) {
        return;
      }
      final audio = res.data['audioBase64'] as String? ?? '';
      final mime = res.data['mimeType'] as String? ?? 'audio/mpeg';
      if (audio.isEmpty) {
        return;
      }
      await _player.stop();
      speaking.value = true;
      unawaited(_player.onPlayerComplete.first.then((_) {
        if (take == _take) {
          speaking.value = false;
        }
      }));
      if (kIsWeb) {
        await _player.play(UrlSource('data:$mime;base64,$audio'));
      } else {
        // A file is the path this app already plays its ringtone through.
        final dir = await getTemporaryDirectory();
        final ext = mime.contains('wav') ? 'wav' : 'mp3';
        final path = p.join(dir.path, 'aivy_reply_$take.$ext');
        await File(path).writeAsBytes(base64Decode(audio), flush: true);
        await _player.play(DeviceFileSource(path));
      }
    } catch (e) {
      debugPrint('[Voice] speak failed: $e');
      if (take == _take) {
        speaking.value = false;
      }
    }
  }

  /// Stops talking, including a reply still being prepared.
  Future<void> stop() async {
    _take++;
    speaking.value = false;
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    await _player.dispose();
    speaking.dispose();
  }
}
