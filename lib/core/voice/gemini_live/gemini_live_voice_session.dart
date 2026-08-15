import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart' show Amplitude;

import '../home_voice_qa_session.dart';
import 'aivy_business_snapshot_service.dart';
import 'aivy_business_tools.dart';
import 'gemini_live_pcm_audio_input.dart';
import 'gemini_live_pcm_audio_output.dart';

/// Real-time Gemini Live voice session with business-data function calling.
class GeminiLiveVoiceSession {
  GeminiLiveVoiceSession({required this.userId})
      : _snapshot = AivyBusinessSnapshotService(userId: userId);

  final String userId;
  final AivyBusinessSnapshotService _snapshot;

  final GeminiLivePcmAudioInput _audioInput = GeminiLivePcmAudioInput();
  final GeminiLivePcmAudioOutput _audioOutput = GeminiLivePcmAudioOutput();

  LiveGenerativeModel? _liveModel;
  LiveSession? _session;
  StreamSubscription<Uint8List>? _micSubscription;
  StreamSubscription<Amplitude>? _ampSub;
  Future<void>? _receiveLoop;
  bool _sessionActive = false;
  bool _disposed = false;
  bool _awaitingModel = false;
  bool _userSpoke = false;
  DateTime? _lastSpeechAt;
  Timer? _silenceForceTurnTimer;

  HomeVoiceQaPhase phase = HomeVoiceQaPhase.idle;
  double lastDb = -160;
  String? lastTranscript;
  String? lastAnswer;

  final List<VoiceConversationTurn> turns = [];

  String _pendingUserText = '';
  String _pendingAssistantText = '';

  /// Diagnosable counters for "listens but never replies".
  int micChunksSent = 0;
  int serverMessages = 0;

  void Function(HomeVoiceQaPhase phase)? onPhaseChanged;
  void Function()? onContentChanged;
  void Function(String message)? onError;

  static const _modelName = 'gemini-2.5-flash-native-audio-preview-12-2025';
  // Web VAD is flaky — after the user has spoken, force a model turn if quiet.
  static const _forceTurnAfterQuietMs = 1400;
  static const _speechDbThreshold = -32.0;

  bool get isSessionActive => _sessionActive;
  bool get isBusy =>
      phase == HomeVoiceQaPhase.processing ||
      phase == HomeVoiceQaPhase.speaking;

  void _setPhase(HomeVoiceQaPhase next) {
    phase = next;
    onPhaseChanged?.call(next);
  }

  Future<void> _prepareAudioSession() async {
    if (kIsWeb) {
      return;
    }
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

  void _initModel() {
    final config = LiveGenerationConfig(
      speechConfig: SpeechConfig(voiceName: 'Aoede'),
      responseModalities: [ResponseModalities.audio],
      inputAudioTranscription: AudioTranscriptionConfig(),
      outputAudioTranscription: AudioTranscriptionConfig(),
    );

    _liveModel = FirebaseAI.googleAI().liveGenerativeModel(
      model: _modelName,
      liveGenerationConfig: config,
      tools: AivyBusinessTools.tools,
      systemInstruction: Content.system(AivyBusinessTools.systemInstruction),
    );
  }

  Future<void> _ensureMicPermission() async {
    // permission_handler is unreliable on web; record's getUserMedia prompt is
    // the real gate there.
    if (kIsWeb) {
      final ok = await _audioInput.hasPermission();
      if (!ok) {
        throw StateError('Microphone permission is required.');
      }
      return;
    }
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      throw StateError('Microphone permission is required.');
    }
  }

  /// Start Gemini Live session and begin streaming mic audio.
  Future<void> startSession() async {
    if (_sessionActive || _disposed) {
      return;
    }

    var stage = 'mic-permission';
    try {
      await _ensureMicPermission();

      stage = 'audio-session';
      await _prepareAudioSession();

      stage = 'init-model';
      _initModel();

      stage = 'mic-init';
      await _audioInput.init();

      stage = 'speaker-init';
      await _audioOutput.init();

      stage = 'connect';
      _session = await _liveModel!
          .connect()
          .timeout(
            const Duration(seconds: 25),
            onTimeout: () => throw StateError(
              'Gemini Live connect timeout — Firebase AI Logic / App Check check karein',
            ),
          );
      _sessionActive = true;
      micChunksSent = 0;
      serverMessages = 0;
      _awaitingModel = false;
      _userSpoke = false;
      _lastSpeechAt = null;

      // Start receive BEFORE mic so we don't drop early setup / greeting msgs.
      // firebase_ai's receive() ends after each turnComplete — loop it.
      _receiveLoop = _processMessagesLoop();

      stage = 'start-playback';
      await _audioOutput.startPlayback();

      stage = 'start-mic-stream';
      final stream = await _audioInput.startRecordingStream();
      if (stream == null) {
        throw StateError('Mic stream could not start');
      }

      _micSubscription = stream.listen(
        (data) {
          final session = _session;
          if (!_sessionActive || session == null || data.isEmpty) {
            return;
          }
          // Do NOT await — awaiting in the listen callback stalls the mic
          // stream on slow networks and drops realtime audio.
          unawaited(() async {
            try {
              await session.sendAudioRealtime(
                InlineDataPart(
                  'audio/pcm;rate=${GeminiLivePcmAudioInput.sampleRate}',
                  data,
                ),
              );
              micChunksSent++;
              if (micChunksSent == 1 || micChunksSent % 40 == 0) {
                onContentChanged?.call();
              }
            } catch (e) {
              debugPrint('[GeminiLive] sendAudioRealtime: $e');
            }
          }());
        },
        onError: (Object e) {
          debugPrint('[GeminiLive] mic stream: $e');
          onError?.call('Mic stream error: $e');
        },
      );

      await _ampSub?.cancel();
      _ampSub = _audioInput.amplitudeStream?.listen(_onAmplitude);

      // Kick the model so the user hears Aivy immediately (also proves
      // playback works). Realtime text + turnComplete starts generation.
      stage = 'greeting';
      try {
        await _session?.sendTextRealtime(
          'User just connected on voice. Greet them briefly in warm Hinglish as Aivy (one short sentence).',
        );
        await _session?.send(turnComplete: true);
        _awaitingModel = true;
      } catch (e) {
        debugPrint('[GeminiLive] greeting kick failed: $e');
      }

      await HapticFeedback.mediumImpact();
      _setPhase(HomeVoiceQaPhase.listening);
    } catch (e) {
      debugPrint('[GeminiLive] startSession failed at [$stage]: $e');
      await _tearDownSession();
      onError?.call('[$stage] ${_friendlyError(e)}');
      rethrow;
    }
  }

  void _onAmplitude(Amplitude amp) {
    lastDb = amp.current;
    if (!_sessionActive || phase == HomeVoiceQaPhase.speaking) {
      return;
    }
    final now = DateTime.now();
    if (amp.current > _speechDbThreshold) {
      _userSpoke = true;
      _lastSpeechAt = now;
      _silenceForceTurnTimer?.cancel();
      _silenceForceTurnTimer = null;
      return;
    }
    if (!_userSpoke || _awaitingModel || _lastSpeechAt == null) {
      return;
    }
    final quietMs = now.difference(_lastSpeechAt!).inMilliseconds;
    if (quietMs < _forceTurnAfterQuietMs) {
      return;
    }
    _silenceForceTurnTimer?.cancel();
    _silenceForceTurnTimer = Timer(const Duration(milliseconds: 50), () {
      unawaited(_forceModelTurn());
    });
  }

  Future<void> _forceModelTurn() async {
    if (!_sessionActive || _awaitingModel || !_userSpoke) {
      return;
    }
    final session = _session;
    if (session == null) {
      return;
    }
    _awaitingModel = true;
    _userSpoke = false;
    try {
      debugPrint('[GeminiLive] silence → force turnComplete');
      await session.send(turnComplete: true);
      onContentChanged?.call();
    } catch (e) {
      debugPrint('[GeminiLive] force turn failed: $e');
      _awaitingModel = false;
    }
  }

  /// Stop the live session and release audio resources.
  Future<void> stopSession() async {
    await _tearDownSession();
    await HapticFeedback.selectionClick();
    _setPhase(HomeVoiceQaPhase.idle);
  }

  Future<void> _tearDownSession() async {
    _sessionActive = false;
    _silenceForceTurnTimer?.cancel();
    _silenceForceTurnTimer = null;
    await _ampSub?.cancel();
    _ampSub = null;
    await _micSubscription?.cancel();
    _micSubscription = null;
    await _audioInput.stopRecording();
    await _audioOutput.stop();
    try {
      await _session?.close();
    } catch (_) {}
    _session = null;
    try {
      await _receiveLoop;
    } catch (_) {}
    _receiveLoop = null;
    _awaitingModel = false;
    _userSpoke = false;
  }

  /// firebase_ai [LiveSession.receive] stops after each turnComplete.
  /// Continuous Gemini-style chat needs us to resubscribe every turn.
  Future<void> _processMessagesLoop() async {
    while (_sessionActive && !_disposed) {
      final session = _session;
      if (session == null) {
        break;
      }
      try {
        await for (final response in session.receive()) {
          if (!_sessionActive || _disposed) {
            break;
          }
          serverMessages++;
          if (serverMessages <= 5 || serverMessages % 20 == 0) {
            debugPrint(
              '[GeminiLive] server msg #$serverMessages '
              '(${response.message.runtimeType}), mic=$micChunksSent',
            );
          }
          await _handleServerMessage(response);
        }
      } catch (e) {
        if (_sessionActive && !_disposed) {
          debugPrint('[GeminiLive] receive loop: $e');
          onError?.call(_friendlyError(e));
        }
        break;
      }
    }
  }

  Future<void> _handleServerMessage(LiveServerResponse response) async {
    final message = response.message;

    if (message is LiveServerContent) {
      if (message.modelTurn != null) {
        await _handleModelTurn(message);
      }

      _handleTranscription(
        message.inputTranscription,
        isUser: true,
      );
      _handleTranscription(
        message.outputTranscription,
        isUser: false,
      );

      if (message.interrupted == true) {
        await _audioOutput.stop();
        await _audioOutput.startPlayback();
        _awaitingModel = false;
        if (phase == HomeVoiceQaPhase.speaking) {
          _setPhase(HomeVoiceQaPhase.listening);
        }
      }

      if (message.turnComplete == true) {
        _awaitingModel = false;
        _userSpoke = false;
        _lastSpeechAt = null;
      }
    } else if (message is LiveServerToolCall &&
        message.functionCalls != null) {
      await _handleToolCall(message);
    }
  }

  Future<void> _handleModelTurn(LiveServerContent content) async {
    final parts = content.modelTurn?.parts;
    if (parts == null) {
      return;
    }

    var hasAudio = false;
    for (final part in parts) {
      if (part is InlineDataPart && part.mimeType.startsWith('audio')) {
        hasAudio = true;
        _audioOutput.playChunk(part.bytes);
      } else if (part is TextPart && part.text.trim().isNotEmpty) {
        _pendingAssistantText += part.text;
        lastAnswer = _pendingAssistantText;
        onContentChanged?.call();
      }
    }

    if (hasAudio && phase != HomeVoiceQaPhase.speaking) {
      _setPhase(HomeVoiceQaPhase.speaking);
    }

    if (content.turnComplete == true) {
      await _audioOutput.finishStream();
      _commitTurnIfReady();
      _awaitingModel = false;
      if (_sessionActive) {
        _setPhase(HomeVoiceQaPhase.listening);
      }
    }
  }

  void _handleTranscription(Transcription? transcription, {required bool isUser}) {
    final text = transcription?.text;
    if (text == null || text.isEmpty) {
      return;
    }

    if (isUser) {
      _pendingUserText += text;
      lastTranscript = _pendingUserText;
    } else {
      _pendingAssistantText += text;
      lastAnswer = _pendingAssistantText;
    }
    onContentChanged?.call();

    if (transcription?.finished == true) {
      _commitTurnIfReady();
    }
  }

  void _commitTurnIfReady() {
    final user = _pendingUserText.trim();
    final assistant = _pendingAssistantText.trim();
    if (assistant.isEmpty) {
      return;
    }
    // Greeting may have no user transcript — still show Aivy's line.
    turns.add(
      VoiceConversationTurn(
        userText: user.isEmpty ? '(connected)' : user,
        assistantText: assistant,
      ),
    );
    _pendingUserText = '';
    _pendingAssistantText = '';
    lastTranscript = null;
    lastAnswer = null;
    onPhaseChanged?.call(phase);
  }

  Future<void> _handleToolCall(LiveServerToolCall message) async {
    final calls = message.functionCalls?.toList() ?? const [];
    if (calls.isEmpty) {
      return;
    }

    _setPhase(HomeVoiceQaPhase.processing);
    final responses = <FunctionResponse>[];

    for (final call in calls) {
      final name = call.name;
      if (name.isEmpty) {
        continue;
      }
      try {
        final result = await _snapshot.executeTool(name, call.args);
        responses.add(
          FunctionResponse(
            name,
            result,
            id: call.id,
          ),
        );
      } catch (e) {
        debugPrint('[GeminiLive] tool $name failed: $e');
        responses.add(
          FunctionResponse(
            name,
            {'error': e.toString()},
            id: call.id,
          ),
        );
      }
    }

    if (responses.isNotEmpty) {
      await _session?.sendToolResponse(responses);
    }

    if (_sessionActive && phase == HomeVoiceQaPhase.processing) {
      _setPhase(HomeVoiceQaPhase.listening);
    }
  }

  void reset() {
    turns.clear();
    lastTranscript = null;
    lastAnswer = null;
    lastDb = -160;
    _pendingUserText = '';
    _pendingAssistantText = '';
    micChunksSent = 0;
    serverMessages = 0;
  }

  String _friendlyError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('permission')) {
      return 'Microphone permission chahiye. Browser address bar me mic allow karein.';
    }
    if (s.contains('unauthenticated') || s.contains('permission-denied')) {
      return 'Please sign in again.';
    }
    if (s.contains('network') || s.contains('socket') || s.contains('timeout')) {
      return 'Internet ya Firebase connection issue — dubara try karein.';
    }
    if (s.contains('app check') ||
        s.contains('appcheck') ||
        s.contains('403') ||
        s.contains('failed-precondition')) {
      return 'App Check / AI Logic setup check karein (Firebase Console).';
    }
    if (s.contains('not found') || s.contains('404') || s.contains('ai logic')) {
      return 'Firebase Console → Build → AI Logic → Get started enable karein.';
    }
    return 'Gemini Live start nahi hua ($e). Setup check karein, phir dubara mic dabayein.';
  }

  Future<void> dispose() async {
    _disposed = true;
    await _tearDownSession();
    await _audioInput.dispose();
    await _audioOutput.dispose();
    turns.clear();
  }
}
