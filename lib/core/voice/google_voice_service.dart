import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

import '../firebase/firebase_session.dart';

/// Calls the `googleSpeechSynthesize` HTTPS callable (Google Cloud TTS).
class GoogleVoiceService {
  GoogleVoiceService({FirebaseFunctions? functions})
    : _functions = functions ?? FirebaseSession.functions;

  final FirebaseFunctions _functions;

  /// Returns a Firebase Storage download URL for the MP3, or null on failure.
  Future<String?> synthesizeToStorage(String text) async {
    final t = text.trim();
    if (t.length < 2) {
      return null;
    }
    if (t.length > 5000) {
      return null;
    }
    try {
      final callable = _functions.httpsCallable('googleSpeechSynthesize');
      final res = await callable.call<Map<String, dynamic>>(<String, dynamic>{
        'text': t,
      });
      final data = res.data;
      final u = data['audioUrl'] as String?;
      final out = u?.trim();
      return out != null && out.isNotEmpty ? out : null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Aivy] googleSpeechSynthesize failed: $e');
      }
      return null;
    }
  }
}
