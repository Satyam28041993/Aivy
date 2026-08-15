import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter_timezone/flutter_timezone.dart';

import '../firebase/firebase_session.dart';

/// Response from [aivyVoiceAsk] — grounded Q&A over report + memory data.
class AivyVoiceAskResult {
  const AivyVoiceAskResult({
    required this.answer,
    required this.transcript,
    this.ttsAudioUrl,
    this.sources,
  });

  final String answer;
  final String transcript;
  /// Pre-synthesized MP3 from `aivyVoiceAsk` (one round-trip faster than client TTS).
  final String? ttsAudioUrl;
  final List<dynamic>? sources;
}

/// Voice assistant Q&A (no actions) via Cloud Function `aivyVoiceAsk`.
class AivyVoiceAskService {
  AivyVoiceAskService({FirebaseFunctions? functions})
    : _functions = functions ?? FirebaseSession.functions;

  final FirebaseFunctions _functions;

  Future<AivyVoiceAskResult> ask({
    String? text,
    String? audioUrl,
    List<Map<String, String>>? history,
  }) async {
    final t = text?.trim() ?? '';
    final u = audioUrl?.trim() ?? '';
    if (t.isEmpty && u.isEmpty) {
      throw ArgumentError('text or audioUrl required');
    }

    String timezone;
    try {
      timezone = await FlutterTimezone.getLocalTimezone();
    } catch (_) {
      timezone = 'Asia/Kolkata';
    }
    final now = DateTime.now().toLocal();
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    final hours = abs.inHours.toString().padLeft(2, '0');
    final minutes = (abs.inMinutes % 60).toString().padLeft(2, '0');
    final nowIso = '${now.toIso8601String()}$sign$hours:$minutes';

    final payload = <String, dynamic>{
      'timezone': timezone,
      'nowIso': nowIso,
      if (t.isNotEmpty) 'text': t,
      if (u.isNotEmpty) 'audioUrl': u,
      if (history != null && history.isNotEmpty) 'history': history,
    };

    final callable = _functions.httpsCallable(
      'aivyVoiceAsk',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 50)),
    );
    try {
      final res = await callable.call<Map<String, dynamic>>(payload);
      final data = res.data;
      final answer = '${data['answer'] ?? ''}'.trim();
      final transcript = '${data['transcript'] ?? t}'.trim();
      if (answer.isEmpty) {
        throw StateError('Empty answer from aivyVoiceAsk');
      }
      final tts = '${data['ttsAudioUrl'] ?? ''}'.trim();
      final sources = data['sources'] as List<dynamic>?;
      return AivyVoiceAskResult(
        answer: answer,
        transcript: transcript,
        ttsAudioUrl: tts.isNotEmpty ? tts : null,
        sources: sources,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Aivy] aivyVoiceAsk failed: $e');
      }
      rethrow;
    }
  }
}
