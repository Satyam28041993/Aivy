import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../features/chat/data/chat_repository.dart';
import '../../features/chat/data/voice_file_upload.dart'
    if (dart.library.io) '../../features/chat/data/voice_file_upload_io.dart'
    as voice_io;
import 'aivy_chat_voice_coordinator.dart';
import 'aivy_voice_ask_service.dart';
import '../../services/google_home_voice_service.dart';

/// Push-to-talk/Hands-free: mic ON → speak → mic OFF → answer.
enum HomeVoiceQaPhase {
  idle,
  listening,
  processing,
  speaking,
}

/// One completed exchange in the live conversation (for premium transcript view).
class VoiceTurn {
  VoiceTurn({required this.question, required this.answer, this.sources});
  final String question;
  final String answer;
  final List<dynamic>? sources;
}

class HomeVoiceQaSession {
  HomeVoiceQaSession({
    required this.userId,
    ChatRepository? repository,
    AivyVoiceAskService? ask,
    GoogleHomeVoiceService? tts,
  }) : _repository = repository ?? ChatRepository(),
       _ask = ask ?? AivyVoiceAskService(),
       _tts = tts ?? GoogleHomeVoiceService();

  final String userId;
  final ChatRepository _repository;
  final AivyVoiceAskService _ask;
  final GoogleHomeVoiceService _tts;

  final AudioRecorder _recorder = AudioRecorder();

  HomeVoiceQaPhase phase = HomeVoiceQaPhase.idle;
  String? lastTranscript;
  String? lastAnswer;
  double lastDb = -160;
  List<dynamic>? lastSources;

  // Premium "Live" conversation mode: after Aivy answers, she keeps listening
  // automatically so the conversation flows continuously (Gemini-style).
  bool handsFreeEnabled = true;
  bool silenceDetectionEnabled = true;

  /// True once the user has started a Live session (first tap). Used so we can
  /// keep looping without re-tapping, and stop the loop cleanly on pause.
  bool _liveActive = false;
  bool get liveActive => _liveActive;

  final List<Map<String, String>> _history = [];

  /// Full running conversation for the premium on-screen transcript.
  final List<VoiceTurn> conversation = [];

  StreamSubscription<Amplitude>? _ampSub;
  DateTime? _startedAt;
  String? _tempPath;
  bool _submitting = false;
  int _recordGen = 0;

  // Silence Detection Tracking
  bool _hasSpoken = false;
  DateTime? _lastSpeechTime;

  // Safety Timeout Timers to absolutely prevent mic hangs
  Timer? _safetyTimer;

  void Function(HomeVoiceQaPhase phase)? onPhaseChanged;
  void Function(String message)? onError;

  bool get isRecording => phase == HomeVoiceQaPhase.listening;
  bool get isBusy =>
      phase == HomeVoiceQaPhase.processing || phase == HomeVoiceQaPhase.speaking;

  /// Enable/disable Live conversation mode. Turning it off stops the auto-loop
  /// and any in-progress listening cleanly.
  Future<void> setHandsFree(bool enabled) async {
    handsFreeEnabled = enabled;
    if (!enabled) {
      _liveActive = false;
      if (phase == HomeVoiceQaPhase.listening) {
        await cancelRecording();
      }
    }
    onPhaseChanged?.call(phase);
  }

  void _setPhase(HomeVoiceQaPhase next) {
    phase = next;
    _startSafetyTimerForPhase(next);
    onPhaseChanged?.call(next);
  }

  /// Safety timer that resets Aivy back to idle if anything stalls (network, cloud function, TTS)
  void _startSafetyTimerForPhase(HomeVoiceQaPhase currentPhase) {
    _safetyTimer?.cancel();
    _safetyTimer = null;

    if (currentPhase == HomeVoiceQaPhase.listening) {
      // Auto-submit after 45 seconds of continuous listening
      _safetyTimer = Timer(const Duration(seconds: 45), () async {
        if (kDebugMode) {
          debugPrint('[Aivy] Safety timeout: listening too long, auto-submitting.');
        }
        if (phase == HomeVoiceQaPhase.listening) {
          await submitRecording();
        }
      });
    } else if (currentPhase == HomeVoiceQaPhase.processing) {
      // Force recover to idle only if the cloud function truly stalls. Aligned
      // closer to the 120s server timeout so we don't bail while it's working.
      _safetyTimer = Timer(const Duration(seconds: 45), () {
        if (kDebugMode) {
          debugPrint('[Aivy] Safety timeout: processing took too long, resetting.');
        }
        if (phase == HomeVoiceQaPhase.processing) {
          _submitting = false;
          _friendlyReset('Thoda slow chal raha hai — dubara boliye.');
        }
      });
    } else if (currentPhase == HomeVoiceQaPhase.speaking) {
      // Stop TTS if speaking runs over 60 seconds
      _safetyTimer = Timer(const Duration(seconds: 60), () {
        if (kDebugMode) {
          debugPrint('[Aivy] Safety timeout: speaking too long, stopping.');
        }
        if (phase == HomeVoiceQaPhase.speaking) {
          unawaited(stopSpeaking());
        }
      });
    }
  }

  void _friendlyReset(String userMessage) {
    _safetyTimer?.cancel();
    _safetyTimer = null;
    _submitting = false;
    _tempPath = null;
    _startedAt = null;
    phase = HomeVoiceQaPhase.idle;
    
    // Provide an error vibration cue
    unawaited(HapticFeedback.heavyImpact());
    
    onError?.call(userMessage);
    onPhaseChanged?.call(HomeVoiceQaPhase.idle);
  }

  /// Mic tap: idle → start recording; listening → stop & send.
  Future<void> toggleMic() async {
    if (_submitting) {
      return;
    }
    if (phase == HomeVoiceQaPhase.listening) {
      // In Live mode a tap while listening means "pause the conversation".
      if (handsFreeEnabled) {
        _liveActive = false;
        await cancelRecording();
        return;
      }
      await submitRecording();
      return;
    }
    // While Aivy is speaking: in Live mode, tapping barges in — stop the reply
    // and immediately start listening so the user can talk over her.
    if (phase == HomeVoiceQaPhase.speaking) {
      await stopSpeaking();
      if (handsFreeEnabled && _liveActive) {
        await startRecording();
      }
      return;
    }
    if (phase == HomeVoiceQaPhase.processing) {
      // Allow user to break/interrupt processing and go back to idle
      _liveActive = false;
      _friendlyReset('Process cancel kiya gaya.');
      return;
    }
    // idle → start. Entering here (re)activates the Live loop.
    _liveActive = handsFreeEnabled;
    await startRecording();
  }

  /// Cancel current recording without sending (also used to pause Live mode).
  /// Prior conversation turns are preserved so context isn't lost on pause.
  Future<void> cancelRecording() async {
    if (phase != HomeVoiceQaPhase.listening) {
      return;
    }
    _recordGen++;
    await _stopRecorderOnly();
    _safetyTimer?.cancel();
    _safetyTimer = null;

    await HapticFeedback.selectionClick();
    _setPhase(HomeVoiceQaPhase.idle);
  }

  /// Full reset: stops all recording/speech, clears screen texts, and resets session history.
  void reset() {
    _recordGen++;
    _liveActive = false;
    _safetyTimer?.cancel();
    _safetyTimer = null;
    unawaited(_stopRecorderOnly());
    unawaited(_tts.stop());
    unawaited(AivyChatVoiceCoordinator.instance.stop());
    lastTranscript = null;
    lastAnswer = null;
    lastSources = null;
    lastDb = -160;
    _history.clear();
    conversation.clear();
    phase = HomeVoiceQaPhase.idle;
    onPhaseChanged?.call(HomeVoiceQaPhase.idle);
  }

  Future<void> stopSpeaking() async {
    _safetyTimer?.cancel();
    _safetyTimer = null;
    await _tts.stop();
    await AivyChatVoiceCoordinator.instance.stop();
    await HapticFeedback.selectionClick();
    if (phase == HomeVoiceQaPhase.speaking) {
      _setPhase(HomeVoiceQaPhase.idle);
    }
  }

  Future<void> startRecording() async {
    if (isBusy || _submitting) {
      return;
    }
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      onError?.call('Microphone permission is required.');
      return;
    }

    final gen = ++_recordGen;
    _safetyTimer?.cancel();
    _safetyTimer = null;
    
    await AivyChatVoiceCoordinator.instance.stop();
    await _tts.stop();
    await _stopRecorderOnly();

    // Pulse a physical cue to signal "Aivy is listening now"
    await HapticFeedback.mediumImpact();

    try {
      await _prepareRecordSession();
      final dir = await getTemporaryDirectory();
      _tempPath = p.join(
        dir.path,
        'aivy_home_qa_${DateTime.now().millisecondsSinceEpoch}.wav',
      );
      if (!await _recorder.hasPermission()) {
        onError?.call('Microphone not available.');
        return;
      }
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: _tempPath!,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Aivy] home QA record start: $e');
      }
      onError?.call('Mic start nahi ho paya — dubara try karein.');
      _setPhase(HomeVoiceQaPhase.idle);
      return;
    }

    if (gen != _recordGen) {
      return;
    }

    _startedAt = DateTime.now();
    lastDb = -160;
    _hasSpoken = false;
    _lastSpeechTime = DateTime.now();
    _setPhase(HomeVoiceQaPhase.listening);

    if (kDebugMode) {
      debugPrint('[Aivy] home QA mic ON (gen=$gen, continuous=$handsFreeEnabled)');
    }

    await _ampSub?.cancel();
    _ampSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 100))
        .listen((amp) {
      if (gen != _recordGen || phase != HomeVoiceQaPhase.listening) {
        return;
      }
      lastDb = amp.current;

      // Smart Silence Detection Logic
      if (silenceDetectionEnabled) {
        final now = DateTime.now();
        // A user speaking typically produces peaks above -28dB in standard mic setups
        if (amp.current > -28.0) {
          if (!_hasSpoken) {
            _hasSpoken = true;
          }
          _lastSpeechTime = now;
        }

        if (_hasSpoken) {
          // If amplitude stays quiet (below -38dB) for ~1.3s, auto-submit. This
          // keeps the conversation snappy without clipping natural pauses.
          if (amp.current < -38.0) {
            if (_lastSpeechTime != null &&
                now.difference(_lastSpeechTime!).inMilliseconds > 1300) {
              // Ensure we recorded at least ~1.1s total to avoid premature triggers
              final totalDurationMs = now.difference(_startedAt!).inMilliseconds;
              if (totalDurationMs >= 1100) {
                _lastSpeechTime = null; // Prevent double submission
                if (kDebugMode) {
                  debugPrint('[Aivy] Smart Silence Detected. Auto-submitting.');
                }
                submitRecording();
              }
            }
          } else {
            _lastSpeechTime = now;
          }
        }
      }
    });
  }

  Future<void> submitRecording() async {
    if (_submitting || phase != HomeVoiceQaPhase.listening) {
      return;
    }
    _submitting = true;
    final gen = _recordGen;
    
    // Physical haptic trigger when finishing listening
    await HapticFeedback.lightImpact();

    try {
      await _ampSub?.cancel();
      _ampSub = null;

      final started = _startedAt;
      _startedAt = null;

      String? stoppedPath;
      try {
        if (await _recorder.isRecording()) {
          stoppedPath = await _recorder.stop();
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Aivy] home QA record stop: $e');
        }
      }

      final localPath = (stoppedPath != null && stoppedPath.isNotEmpty)
          ? stoppedPath
          : _tempPath;
      _tempPath = null;

      if (gen != _recordGen) {
        return;
      }

      if (localPath == null || started == null) {
        onError?.call('Recording save nahi hui — dubara try karein.');
        _setPhase(HomeVoiceQaPhase.idle);
        return;
      }

      final durationMs = DateTime.now().difference(started).inMilliseconds;
      final bytes = await voice_io.voiceLocalFileByteLength(localPath);
      if (kDebugMode) {
        debugPrint('[Aivy] home QA mic OFF — ${durationMs}ms, $bytes bytes');
      }

      if (durationMs < 350) {
        onError?.call('Bahut chhota — thoda aur der boliye, phir mic band karein.');
        _setPhase(HomeVoiceQaPhase.idle);
        return;
      }
      if (bytes < 500) {
        onError?.call('Awaz record nahi hui — mic ON karke dubara boliye.');
        _setPhase(HomeVoiceQaPhase.idle);
        return;
      }

      await _processRecording(localPath);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Aivy] submitRecording error: $e');
      }
      _friendlyReset('Recording processing fail ho gayi.');
    } finally {
      _submitting = false;
    }
  }

  Future<void> _processRecording(String localPath) async {
    _setPhase(HomeVoiceQaPhase.processing);
    try {
      if (kDebugMode) {
        debugPrint('[Aivy] home QA uploading…');
      }
      final entryId = 'ask_${DateTime.now().millisecondsSinceEpoch}';
      final url = await _repository.uploadVoiceFile(
        userId: userId,
        entryId: entryId,
        localFilePath: localPath,
      );

      if (kDebugMode) {
        debugPrint('[Aivy] home QA calling aivyVoiceAsk…');
      }
      final result = await _ask.ask(
        audioUrl: url,
        history: _history.isNotEmpty ? _history : null,
      );
      lastTranscript = result.transcript;
      lastAnswer = result.answer;
      lastSources = result.sources;

      if (lastTranscript != null && lastTranscript!.trim().isNotEmpty &&
          lastAnswer != null && lastAnswer!.trim().isNotEmpty) {
        _history.add({'role': 'user', 'text': lastTranscript!});
        _history.add({'role': 'model', 'text': lastAnswer!});
        if (_history.length > 6) {
          _history.removeRange(0, _history.length - 6);
        }
        conversation.add(VoiceTurn(
          question: lastTranscript!,
          answer: lastAnswer!,
          sources: result.sources,
        ));
        if (conversation.length > 30) {
          conversation.removeRange(0, conversation.length - 30);
        }
      }

      if (kDebugMode) {
        debugPrint(
          '[Aivy] home QA got answer (${result.answer.length} chars), '
          'tts=${result.ttsAudioUrl != null}',
        );
      }

      if (result.answer.trim().isEmpty) {
        onError?.call('Jawab khali aaya — dubara poochiye.');
        _setPhase(HomeVoiceQaPhase.idle);
        return;
      }

      _setPhase(HomeVoiceQaPhase.speaking);
      await AivyChatVoiceCoordinator.instance.stop();
      try {
        await _tts.speakAndWait(
          text: result.answer,
          audioUrl: result.ttsAudioUrl,
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Aivy] home QA TTS error, client fallback: $e');
        }
        await _tts.speakAndWait(text: result.answer);
      }

      _setPhase(HomeVoiceQaPhase.idle);
      if (kDebugMode) {
        debugPrint('[Aivy] home QA ready — tap mic for next question');
      }

      // Live loop: automatically resume listening after a short, natural gap so
      // the conversation keeps flowing without the user tapping again.
      if (handsFreeEnabled && _liveActive) {
        Timer(const Duration(milliseconds: 450), () {
          if (phase == HomeVoiceQaPhase.idle && handsFreeEnabled && _liveActive) {
            startRecording();
          }
        });
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Aivy] home QA failed: $e');
      }
      _friendlyReset(_friendlyError(e));
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('unauthenticated')) {
      return 'Please sign in again.';
    }
    if (s.contains('network') || s.contains('Unable to resolve host')) {
      return 'Internet check karein — connection issue.';
    }
    if (s.contains('Could not understand')) {
      return 'Samajh nahi aaya — saaf bol kar dubara try karein.';
    }
    return 'Voice error — dubara try karein.';
  }

  Future<void> _prepareRecordSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(
        AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetooth |
              AVAudioSessionCategoryOptions.defaultToSpeaker,
          avAudioSessionMode: AVAudioSessionMode.spokenAudio,
          androidAudioAttributes: const AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            usage: AndroidAudioUsage.voiceCommunication,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        ),
      );
      await session.setActive(true);
    } catch (_) {}
  }

  Future<void> _stopRecorderOnly() async {
    await _ampSub?.cancel();
    _ampSub = null;
    _startedAt = null;
    _safetyTimer?.cancel();
    _safetyTimer = null;
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}
  }

  Future<void> dispose() async {
    _recordGen++;
    _safetyTimer?.cancel();
    _safetyTimer = null;
    await _stopRecorderOnly();
    await _tts.stop();
    await _tts.dispose();
    _history.clear();
    try {
      await _recorder.dispose();
    } catch (_) {}
  }
}
