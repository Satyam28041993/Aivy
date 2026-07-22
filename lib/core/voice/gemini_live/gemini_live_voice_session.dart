import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:permission_handler/permission_handler.dart';

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
  Future<void>? _receiveLoop;
  bool _sessionActive = false;
  bool _disposed = false;

  HomeVoiceQaPhase phase = HomeVoiceQaPhase.idle;
  double lastDb = -160;
  String? lastTranscript;
  String? lastAnswer;

  final List<VoiceConversationTurn> turns = [];

  String _pendingUserText = '';
  String _pendingAssistantText = '';

  void Function(HomeVoiceQaPhase phase)? onPhaseChanged;
  void Function(String message)? onError;

  static const _modelName = 'gemini-2.5-flash-native-audio-preview-12-2025';

  bool get isSessionActive => _sessionActive;
  bool get isBusy =>
      phase == HomeVoiceQaPhase.processing ||
      phase == HomeVoiceQaPhase.speaking;

  void _setPhase(HomeVoiceQaPhase next) {
    phase = next;
    onPhaseChanged?.call(next);
  }

  Future<void> _prepareAudioSession() async {
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

  /// Start Gemini Live session and begin streaming mic audio.
  Future<void> startSession() async {
    if (_sessionActive || _disposed) {
      return;
    }

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      onError?.call('Microphone permission is required.');
      return;
    }

    try {
      await _prepareAudioSession();
      _initModel();
      await _audioInput.init();
      await _audioOutput.init();

      _session = await _liveModel!
          .connect()
          .timeout(
            const Duration(seconds: 25),
            onTimeout: () => throw StateError(
              'Gemini Live connect timeout — Firebase AI Logic / App Check check karein',
            ),
          );
      _sessionActive = true;
      _receiveLoop = _processMessages();

      await _audioOutput.startPlayback();
      final stream = await _audioInput.startRecordingStream();
      if (stream == null) {
        throw StateError('Mic stream could not start');
      }

      _micSubscription = stream.listen(
        (data) async {
          final session = _session;
          if (!_sessionActive || session == null) {
            return;
          }
          try {
            await session.sendAudioRealtime(InlineDataPart('audio/pcm', data));
          } catch (e) {
            debugPrint('[GeminiLive] sendAudioRealtime: $e');
          }
        },
        onError: (Object e) {
          debugPrint('[GeminiLive] mic stream: $e');
        },
      );

      _audioInput.amplitudeStream?.listen((amp) {
        lastDb = amp.current;
      });

      await HapticFeedback.mediumImpact();
      _setPhase(HomeVoiceQaPhase.listening);
    } catch (e) {
      debugPrint('[GeminiLive] startSession failed: $e');
      await _tearDownSession();
      onError?.call(_friendlyError(e));
      rethrow;
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
  }

  Future<void> _processMessages() async {
    final session = _session;
    if (session == null) {
      return;
    }
    try {
      await for (final response in session.receive()) {
        if (!_sessionActive || _disposed) {
          break;
        }
        await _handleServerMessage(response);
      }
    } catch (e) {
      if (_sessionActive && !_disposed) {
        debugPrint('[GeminiLive] receive loop: $e');
        onError?.call(_friendlyError(e));
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
        if (phase == HomeVoiceQaPhase.speaking) {
          _setPhase(HomeVoiceQaPhase.listening);
        }
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
      }
    }

    if (hasAudio && phase != HomeVoiceQaPhase.speaking) {
      _setPhase(HomeVoiceQaPhase.speaking);
    }

    if (content.turnComplete == true) {
      await _audioOutput.finishStream();
      _commitTurnIfReady();
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

    if (transcription?.finished == true) {
      _commitTurnIfReady();
    }
  }

  void _commitTurnIfReady() {
    final user = _pendingUserText.trim();
    final assistant = _pendingAssistantText.trim();
    if (user.isEmpty || assistant.isEmpty) {
      return;
    }
    turns.add(VoiceConversationTurn(userText: user, assistantText: assistant));
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
  }

  String _friendlyError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('permission')) {
      return 'Microphone permission chahiye.';
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
      return 'App Check token register karein: Firebase Console → App Check → '
          'Android app → Manage debug tokens. Pehli baar app kholo, logcat mein '
          '"debug secret" copy karke add karein. AI Logic bhi enable hona chahiye.';
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
