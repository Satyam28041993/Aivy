import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../data/voice_file_upload.dart'
    if (dart.library.io) '../data/voice_file_upload_io.dart' as voice_io;

import '../../../core/speech/dictation_text.dart';
import '../../../core/speech/local_speech_to_text.dart';
import '../../../core/voice/aivy_chat_voice_coordinator.dart';
import '../../../core/voice/google_voice_service.dart';
import '../application/assistant_google_voice_completion.dart';
import '../application/controlled_chat_flow.dart';
import '../application/user_text_pipeline.dart';
import 'controlled_flow_coordinator.dart';
import '../data/aivy_process_service.dart';
import '../data/chat_flow_state.dart';
import '../data/chat_repository.dart';
import '../models/chat_message.dart';
import 'widgets/aivy_chat_quick_actions.dart';
import 'widgets/chat_conversation_view.dart';
import 'widgets/chat_sessions_sidebar.dart';

import '../utils/aivy_response_formatter.dart';
import '../../../core/theme/aivy_theme.dart';
import '../../dashboard/presentation/widgets/ai_input_bar.dart';
import '../../reminders/data/reminder_repository.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.userId,
    required this.activeChatId,
    required this.onNewChat,
    required this.onSelectChat,
    required this.onDeleteChat,
  });

  final String userId;
  final String? activeChatId;
  final Future<void> Function() onNewChat;
  final Future<void> Function(String chatId) onSelectChat;
  final Future<void> Function(String chatId) onDeleteChat;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatRepository _repository;
  late final AivyProcessService _aivyProcessService;
  late final GoogleVoiceService _googleVoice;
  late final ControlledChatFlow _controlledFlow;
  late UserTextPipeline _textPipeline;
  final LocalSpeechToText _localSpeech = LocalSpeechToText();
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  final GlobalKey<ScaffoldState> _narrowScaffoldKey = GlobalKey<ScaffoldState>();

  bool _isSending = false;
  final ReminderRepository _reminders = ReminderRepository();
  /// True while the user is holding the mic and native dictation is active.
  bool _isNativeDictating = false;
  String _liveTranscript = '';
  /// Matches physical press on the mic (handles async init vs. quick release).
  bool _holdMic = false;
  /// When true, this hold captures AAC audio for server-side Gemini transcription.
  bool _holdUsesCloudRecorder = false;
  final AudioRecorder _voiceRecorder = AudioRecorder();
  String? _voiceTempPath;
  DateTime? _voiceRecordStartedAt;
  Timer? _voiceElapsedTimer;

  /// Continuous listen: auto-stop on silence, then same cloud voice pipeline.
  bool _handsFreeListening = false;
  StreamSubscription<Amplitude>? _handsFreeAmpSub;
  Timer? _handsFreeMonitorTimer;
  DateTime? _handsFreeLastLoudAt;
  String? _handsFreeTempPath;
  DateTime? _handsFreeStartedAt;
  double _handsFreeLastDb = -160;
  bool _handsFreeFinishing = false;

  /// Monitors the latest [ _sendMessage ] call so stale completions never touch state.
  int _sendGeneration = 0;
  String? _waPrefillConsumedToken;

  @override
  void initState() {
    super.initState();
    _repository = ChatRepository();
    _aivyProcessService = AivyProcessService();
    _googleVoice = GoogleVoiceService();
    _controlledFlow = ControlledChatFlow(
      ledgerRepository: _repository,
      waLineTranslator: (line) =>
          _aivyProcessService.translateForWhatsappPreview(line),
    );
    final cid = widget.activeChatId;
    _textPipeline = UserTextPipeline(
      userId: widget.userId,
      chatId: cid ?? '',
      repository: _repository,
      aivyProcessService: _aivyProcessService,
      googleVoice: _googleVoice,
    );
    _textController.addListener(_onTextChanged);
    _controlledFlow.confirmSaveBusy.addListener(_onConfirmSaveBusy);
    unawaited(_reminders.syncPendingReminderNotifications(widget.userId));
  }

  void _onConfirmSaveBusy() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final n = widget.activeChatId;
    if (n != null && n != oldWidget.activeChatId) {
      _textPipeline = UserTextPipeline(
        userId: widget.userId,
        chatId: n,
        repository: _repository,
        aivyProcessService: _aivyProcessService,
        googleVoice: _googleVoice,
      );
    }
  }

  void _onTextChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _controlledFlow.confirmSaveBusy.removeListener(_onConfirmSaveBusy);
    _textController.dispose();
    _inputFocus.dispose();
    _scrollController.dispose();
    _voiceElapsedTimer?.cancel();
    unawaited(_cancelHandsFreeForDispose());
    unawaited(_stopVoiceRecorderForDispose());
    if (_localSpeech.isListening) {
      unawaited(_localSpeech.stop());
    }
    _aivyProcessService.dispose();
    super.dispose();
  }

  Future<void> _cancelHandsFreeForDispose() async {
    _handsFreeMonitorTimer?.cancel();
    _handsFreeMonitorTimer = null;
    await _handsFreeAmpSub?.cancel();
    _handsFreeAmpSub = null;
    _handsFreeListening = false;
    _handsFreeTempPath = null;
    _handsFreeStartedAt = null;
    try {
      if (await _voiceRecorder.isRecording()) {
        await _voiceRecorder.stop();
      }
    } catch (_) {}
  }

  Future<void> _stopVoiceRecorderForDispose() async {
    try {
      if (await _voiceRecorder.isRecording()) {
        await _voiceRecorder.stop();
      }
    } catch (_) {}
    try {
      await _voiceRecorder.dispose();
    } catch (_) {}
  }

  String _formatVoiceHoldDuration() {
    final start = _voiceRecordStartedAt;
    if (start == null) {
      return '0:00';
    }
    final s = DateTime.now().difference(start).inSeconds;
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  Future<void> _toggleHandsFreeVoice() async {
    if (kIsWeb) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Hands-free voice is not available on web yet.')),
        );
      }
      return;
    }
    if (_handsFreeFinishing) {
      return;
    }
    if (_handsFreeListening) {
      await _finishHandsFreeSubmit(manualStop: true);
      return;
    }
    if (_isSending || _controlledFlow.confirmSaveBusy.value) {
      return;
    }
    if (_holdMic || _isNativeDictating) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pehle mic hold band karein.')),
        );
      }
      return;
    }
    final chatId = widget.activeChatId;
    if (chatId == null || chatId.isEmpty) {
      return;
    }

    await AivyChatVoiceCoordinator.instance.stop();

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Microphone permission is required for voice.'),
          action: status.isPermanentlyDenied
              ? SnackBarAction(label: 'Settings', onPressed: openAppSettings)
              : null,
        ),
      );
      return;
    }

    final flow = await _repository.fetchChatFlowState(widget.userId);
    if (ControlledChatFlow.isControlledFlowBlockingGenericAi(flow)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Is flow ke dauran hands-free voice band hai.'),
          ),
        );
      }
      return;
    }

    try {
      final dir = await getTemporaryDirectory();
      final fp = p.join(
        dir.path,
        'aivy_hf_${DateTime.now().millisecondsSinceEpoch}.wav',
      );
      _handsFreeTempPath = fp;
      if (!await _voiceRecorder.hasPermission()) {
        return;
      }
      await _voiceRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: fp,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Aivy] hands-free start failed: $e');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Voice start failed: $e')),
        );
      }
      return;
    }

    _handsFreeStartedAt = DateTime.now();
    _handsFreeLastLoudAt = null;
    _handsFreeLastDb = -160;
    _handsFreeListening = true;

    await _handsFreeAmpSub?.cancel();
    _handsFreeAmpSub = _voiceRecorder
        .onAmplitudeChanged(const Duration(milliseconds: 220))
        .listen((amp) {
      _handsFreeLastDb = amp.current;
      if (amp.current > -34) {
        _handsFreeLastLoudAt = DateTime.now();
      }
      if (mounted) {
        setState(() {});
      }
    });

    _handsFreeMonitorTimer?.cancel();
    _handsFreeMonitorTimer = Timer.periodic(
      const Duration(milliseconds: 320),
      (_) => _tickHandsFreeSilence(),
    );

    await HapticFeedback.lightImpact();
    if (mounted) {
      setState(() {});
    }
  }

  void _tickHandsFreeSilence() {
    if (!_handsFreeListening || !mounted) {
      return;
    }
    final start = _handsFreeStartedAt;
    if (start == null) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(start).inMilliseconds < 700) {
      return;
    }
    final loudAt = _handsFreeLastLoudAt;
    if (loudAt == null) {
      if (now.difference(start).inSeconds > 22) {
        unawaited(_finishHandsFreeSubmit(manualStop: false, tooQuiet: true));
      }
      return;
    }
    if (now.difference(loudAt).inMilliseconds > 1350) {
      unawaited(_finishHandsFreeSubmit(manualStop: false));
    }
  }

  Future<void> _finishHandsFreeSubmit({
    required bool manualStop,
    bool tooQuiet = false,
  }) async {
    if (_handsFreeFinishing) {
      return;
    }
    if (!_handsFreeListening && _handsFreeTempPath == null) {
      return;
    }
    _handsFreeFinishing = true;
    try {
    _handsFreeMonitorTimer?.cancel();
    _handsFreeMonitorTimer = null;
    await _handsFreeAmpSub?.cancel();
    _handsFreeAmpSub = null;

    final started = _handsFreeStartedAt;
    _handsFreeStartedAt = null;
    _handsFreeListening = false;

    String? stoppedPath;
    try {
      if (await _voiceRecorder.isRecording()) {
        stoppedPath = await _voiceRecorder.stop();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Aivy] hands-free stop: $e');
      }
    }

    final localPath = (stoppedPath != null && stoppedPath.isNotEmpty)
        ? stoppedPath
        : _handsFreeTempPath;
    _handsFreeTempPath = null;
    _handsFreeLastLoudAt = null;

    if (mounted) {
      setState(() {});
    }

    if (tooQuiet) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Zyaada shor nahi mila — dubara boliye.')),
        );
      }
      return;
    }

    if (localPath == null || started == null) {
      return;
    }
    final durationMs = DateTime.now().difference(started).inMilliseconds;
    if (manualStop && durationMs < 500) {
      return;
    }
    final bytes = await voice_io.voiceLocalFileByteLength(localPath);
    if (durationMs < 450 || bytes < 1400) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Thoda aur der boliye — phir bhejenge.'),
          ),
        );
      }
      return;
    }

    unawaited(
      _submitCloudVoiceMessage(localPath: localPath, durationMs: durationMs),
    );
    } finally {
      _handsFreeFinishing = false;
    }
  }

  Future<void> _onMicDown() async {
    if (kIsWeb) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Voice send is not available on web yet.'),
          ),
        );
      }
      return;
    }
    if (_isSending || _controlledFlow.confirmSaveBusy.value) {
      return;
    }
    if (_handsFreeListening) {
      return;
    }

    await AivyChatVoiceCoordinator.instance.stop();

    _holdMic = true;
    _holdUsesCloudRecorder = false;
    _liveTranscript = '';
    _inputFocus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      _holdMic = false;
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Microphone permission is required to dictate.'),
          action: status.isPermanentlyDenied
              ? SnackBarAction(
                  label: 'Settings',
                  onPressed: openAppSettings,
                )
              : null,
        ),
      );
      return;
    }

    if (!_holdMic) {
      return;
    }

    final flow = await _repository.fetchChatFlowState(widget.userId);
    final blockGeneric =
        ControlledChatFlow.isControlledFlowBlockingGenericAi(flow);

    if (!blockGeneric) {
      try {
        final dir = await getTemporaryDirectory();
        final fp = p.join(
          dir.path,
          'aivy_voice_${DateTime.now().millisecondsSinceEpoch}.wav',
        );
        _voiceTempPath = fp;
        if (await _voiceRecorder.hasPermission()) {
          await _voiceRecorder.start(
            const RecordConfig(
              encoder: AudioEncoder.wav,
              sampleRate: 16000,
              numChannels: 1,
            ),
            path: fp,
          );
          _holdUsesCloudRecorder = true;
          _voiceRecordStartedAt = DateTime.now();
          _voiceElapsedTimer?.cancel();
          _voiceElapsedTimer = Timer.periodic(
            const Duration(milliseconds: 400),
            (_) {
              if (mounted && _holdMic && _holdUsesCloudRecorder) {
                setState(() {});
              }
            },
          );
          await HapticFeedback.lightImpact();
          if (!mounted || !_holdMic) {
            await _silenceVoiceRecorderAfterQuickRelease();
            return;
          }
          setState(() {
            _isNativeDictating = true;
            _liveTranscript = '';
          });
          return;
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Aivy] voice recorder start failed: $e');
        }
        _voiceTempPath = null;
        _holdUsesCloudRecorder = false;
        _voiceRecordStartedAt = null;
      }
    }

    _holdUsesCloudRecorder = false;
    final ok = await _localSpeech.initialize();
    if (!_holdMic) {
      if (_localSpeech.isListening) {
        await _localSpeech.stop();
      }
      return;
    }
    if (!ok) {
      _holdMic = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Speech recognition is not available on this device.'),
          ),
        );
      }
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _isNativeDictating = true;
      _liveTranscript = '';
    });

    try {
      var committedPrefix = '';
      var firstSegment = true;
      while (_holdMic && mounted) {
        await _localSpeech.listen(
          hapticOnStart: firstSegment,
          onText: (text) {
            if (!mounted) {
              return;
            }
            final merged = mergeDictationHypothesis(committedPrefix, text);
            setState(() => _liveTranscript = dedupeConsecutiveWords(merged));
          },
        );
        firstSegment = false;
        committedPrefix = _liveTranscript.trim();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Aivy] listen error: $e');
      }
      if (mounted) {
        setState(() {
          _isNativeDictating = false;
          _liveTranscript = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Speech recognition failed: $e')),
        );
      }
      return;
    }

    if (!_holdMic && _localSpeech.isListening) {
      await _localSpeech.stop();
    }
  }

  Future<void> _silenceVoiceRecorderAfterQuickRelease() async {
    _voiceElapsedTimer?.cancel();
    _voiceElapsedTimer = null;
    _holdUsesCloudRecorder = false;
    _voiceRecordStartedAt = null;
    _voiceTempPath = null;
    try {
      if (await _voiceRecorder.isRecording()) {
        await _voiceRecorder.stop();
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _isNativeDictating = false;
        _liveTranscript = '';
      });
    }
  }

  Future<void> _onMicUp() async {
    _holdMic = false;
    _voiceElapsedTimer?.cancel();
    _voiceElapsedTimer = null;

    final usedCloud = _holdUsesCloudRecorder;
    _holdUsesCloudRecorder = false;

    if (usedCloud) {
      await _localSpeech.stop();
      DateTime? started = _voiceRecordStartedAt;
      _voiceRecordStartedAt = null;
      String? stoppedPath;
      try {
        stoppedPath = await _voiceRecorder.stop();
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[Aivy] voice recorder stop: $e');
        }
      }
      final localPath = (stoppedPath != null && stoppedPath.isNotEmpty)
          ? stoppedPath
          : _voiceTempPath;
      _voiceTempPath = null;

      if (!mounted) {
        return;
      }
      setState(() {
        _isNativeDictating = false;
        _liveTranscript = '';
      });

      if (localPath != null &&
          started != null &&
          !_isSending &&
          !_controlledFlow.confirmSaveBusy.value) {
        final durationMs = DateTime.now().difference(started).inMilliseconds;
        final bytes = await voice_io.voiceLocalFileByteLength(localPath);
        if (durationMs >= 450 && bytes >= 1400) {
          unawaited(_submitCloudVoiceMessage(
            localPath: localPath,
            durationMs: durationMs,
          ));
          return;
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Thoda aur der mic dabayein — awaaz record hone ke baad bhejenge.',
            ),
          ),
        );
      }
      return;
    }

    await _localSpeech.stop();
    if (!mounted) {
      return;
    }
    final said = _liveTranscript.trim();
    setState(() {
      _isNativeDictating = false;
      _liveTranscript = '';
    });
    if (said.isNotEmpty) {
      await _sendMessageWithText(said);
    }
  }

  Future<void> _submitCloudVoiceMessage({
    required String localPath,
    required int durationMs,
  }) async {
    if (_isSending || _controlledFlow.confirmSaveBusy.value) {
      return;
    }
    final chatId = widget.activeChatId;
    if (chatId == null || chatId.isEmpty) {
      return;
    }

    final sendToken = ++_sendGeneration;
    if (mounted) {
      setState(() {
        _isSending = true;
      });
    }

    String? entryId;
    try {
      entryId = await _repository.createEntry(
        userId: widget.userId,
        rawInput: 'Voice message',
        source: 'voice',
      );

      final url = await _repository.uploadVoiceFile(
        userId: widget.userId,
        entryId: entryId,
        localFilePath: localPath,
      );

      final aiResponse = await _aivyProcessService.analyzeVoice(url);

      var transcript = aiResponse.transcript?.trim() ?? '';
      if (transcript.isEmpty) {
        transcript = UserTextPipeline.intentRoutingText(aiResponse);
      }
      if (transcript.isEmpty) {
        transcript = 'Voice message';
      }

      await _repository.patchEntryRawInput(
        userId: widget.userId,
        entryId: entryId,
        rawInput: transcript,
      );

      await _repository.addMessage(
        userId: widget.userId,
        chatId: chatId,
        role: ChatRole.user,
        text: transcript,
        entryId: entryId,
        audioUrl: url,
        durationMs: durationMs,
      );

      await _repository.trySetChatTitleIfDefault(
        userId: widget.userId,
        chatId: chatId,
        userText: transcript,
      );

      final ttsUrl = await AssistantGoogleVoiceCompletion.maybeSynthesizeTtsUrl(
        voice: _googleVoice,
        response: aiResponse,
      );

      await _repository.completeEntryWithAgentActivation(
        userId: widget.userId,
        chatId: chatId,
        entryId: entryId,
        response: aiResponse,
        userRawInput: transcript,
        assistantTtsUrl: ttsUrl,
      );
    } catch (error) {
      if (entryId != null) {
        await _repository.failEntry(
          userId: widget.userId,
          entryId: entryId,
          reason: error.toString(),
        );
        await _repository.addMessage(
          userId: widget.userId,
          chatId: chatId,
          role: ChatRole.assistant,
          text: generateAivyResponse('error', const {}),
          entryId: entryId,
          isError: true,
        );
      }
    } finally {
      if (mounted && sendToken == _sendGeneration) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  void _maybeApplyWaComposerPrefill(ChatFlowState? s) {
    if (s == null) {
      return;
    }
    if (s.pendingAction != ChatFlowState.actionAwaitingWhatsappSendMessage) {
      return;
    }
    final pre = '${s.pendingData['prefillMessage'] ?? ''}'.trim();
    final token = '${s.pendingData['prefillToken'] ?? ''}'.trim();
    if (pre.isEmpty || token.isEmpty) {
      return;
    }
    if (_waPrefillConsumedToken == token) {
      return;
    }
    _waPrefillConsumedToken = token;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _textController.text = pre;
      _textController.selection =
          TextSelection.collapsed(offset: pre.length);
      setState(() {});
    });
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _textController.clear();
    setState(() {});
    await _sendMessageWithText(text);
  }

  /// Sends a user line without going through the input field (e.g. order picker).
  Future<void> _sendQuickText(String text) => _sendMessageWithText(text.trim());

  Future<void> _sendMessageWithText(String text) async {
    if (_isSending ||
        _controlledFlow.confirmSaveBusy.value) {
      return;
    }

    final chatId = widget.activeChatId;
    if (chatId == null || chatId.isEmpty) {
      return;
    }

    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }

    final sendToken = ++_sendGeneration;

    setState(() {
      _isSending = true;
    });

    String? entryId;
    try {
      entryId = await _repository.createEntry(
        userId: widget.userId,
        rawInput: trimmed,
      );

      await _repository.addMessage(
        userId: widget.userId,
        chatId: chatId,
        role: ChatRole.user,
        text: trimmed,
        entryId: entryId,
      );

      await _repository.trySetChatTitleIfDefault(
        userId: widget.userId,
        chatId: chatId,
        userText: trimmed,
      );

      await _processUserMessage(trimmed, entryId);
    } catch (error) {
      if (entryId != null) {
        await _repository.failEntry(
          userId: widget.userId,
          entryId: entryId,
          reason: error.toString(),
        );
      }

      await _repository.addMessage(
        userId: widget.userId,
        chatId: chatId,
        role: ChatRole.assistant,
        text: generateAivyResponse('error', const {}),
        entryId: entryId,
        isError: true,
      );
    } finally {
      if (mounted && sendToken == _sendGeneration) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  Future<void> _processUserMessage(String text, String entryId) async {
    final chatId = widget.activeChatId;
    if (chatId == null || chatId.isEmpty) {
      return;
    }
    final r = await _controlledFlow.process(
      userId: widget.userId,
      text: text,
    );
    if (kDebugMode) {
      debugPrint(
        '[AIVY_TRACE_CONFIRM] ChatScreen._processUserMessage after process '
        'kind=${r.kind} handled=${r.handled} mounted=$mounted '
        'confirmDraftSet=${r.confirmDraft != null} '
        'confirmMapKeys=${r.confirmDraftMap?.keys.toList()}',
      );
    }
    if (r.handled) {
      if (!mounted) {
        if (kDebugMode) {
          debugPrint(
            '[AIVY_TRACE_CONFIRM] ChatScreen SKIPPED ControlledFlowCoordinator.apply '
            '(!mounted) kind=${r.kind}',
          );
        }
        return;
      }
      await ControlledFlowCoordinator.apply(
        context: context,
        result: r,
        userId: widget.userId,
        chatId: chatId,
        entryId: entryId,
        repository: _repository,
        flow: _controlledFlow,
        aivy: _aivyProcessService,
        googleVoice: _googleVoice,
      );
      return;
    }
    if (kDebugMode) {
      debugPrint(
        '[AIVY_TRACE_CONFIRM] ChatScreen FALLBACK UserTextPipeline '
        'handled=false kind=${r.kind}',
      );
    }
    await _textPipeline.processUserMessage(text, entryId);
  }

  /// Bottom bar chips: follow [ControlledChatFlow] + [ChatFlowState.pendingAction].
  List<FlowQuickChip>? _flowChipOverride(ChatFlowState? s) {
    if (s == null) {
      return null;
    }
    final pa = s.pendingAction;
    if (pa == ChatFlowState.actionAwaitingChatConfirm) {
      return const [
        FlowQuickChip(label: 'Confirm', sendText: 'Confirm'),
        FlowQuickChip(label: 'Edit', sendText: 'Edit'),
        FlowQuickChip(label: 'Cancel', sendText: 'Cancel'),
      ];
    }
    if (pa == ChatFlowState.actionEditingConfirm) {
      final mode = s.pendingData['editingMode'] as String? ?? 'pick';
      if (mode != 'pick') {
        return null;
      }
      return const [
        FlowQuickChip(label: '1 · Name', sendText: '1'),
        FlowQuickChip(label: '2 · Amount', sendText: '2'),
        FlowQuickChip(label: '3 · Date', sendText: '3'),
        FlowQuickChip(label: '4 · Note', sendText: '4'),
      ];
    }
    if (pa == ChatFlowState.actionAwaitingContinue) {
      return const [
        FlowQuickChip(label: 'Yes · continue', sendText: 'Yes'),
        FlowQuickChip(label: 'Cancel flow', sendText: 'Cancel'),
      ];
    }
    if (pa == ChatFlowState.actionAwaitingDisambig) {
      return const [
        FlowQuickChip(label: '1 · Payment due', sendText: '1'),
        FlowQuickChip(label: '2 · Reminder', sendText: '2'),
      ];
    }
    return null;
  }

  bool get _hasText => _textController.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final chatId = widget.activeChatId;

    return Theme(
      data: AivyTheme.darkDashboard(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 760;
          final topPad = wide
              ? MediaQuery.paddingOf(context).top + 16
              : 12.0;

          final sidebar = ChatSessionsSidebar(
            userId: widget.userId,
            repository: _repository,
            activeChatId: chatId,
            compact: !wide,
            onNewChat: () async {
              await widget.onNewChat();
              if (mounted) {
                _narrowScaffoldKey.currentState?.closeDrawer();
              }
            },
            onSelectChat: (id) async {
              await widget.onSelectChat(id);
              if (mounted) {
                _narrowScaffoldKey.currentState?.closeDrawer();
              }
            },
            onDeleteChat: (id) async {
              await widget.onDeleteChat(id);
              if (mounted) {
                _narrowScaffoldKey.currentState?.closeDrawer();
              }
            },
          );

          final chatColumn = Column(
            children: [
              Expanded(
                child: chatId == null
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFFA78BFA),
                        ),
                      )
                    : ChatConversationView(
                        key: ValueKey<String>(chatId),
                        userId: widget.userId,
                        chatId: chatId,
                        repository: _repository,
                        scrollController: _scrollController,
                        topPadding: topPad,
                        isAwaitingAssistant: _isSending,
                        onQuickSend: _sendQuickText,
                        autoPlayAssistantTts: true,
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_isNativeDictating || _handsFreeListening) _buildDictationStrip(),
                      StreamBuilder<ChatFlowState>(
                        stream:
                            _repository.watchChatFlowState(widget.userId),
                        builder: (context, snap) {
                          _maybeApplyWaComposerPrefill(snap.data);
                          return AivyChatQuickActions(
                            enabled:
                                !_isSending && !_controlledFlow.confirmSaveBusy.value,
                            flowChipOverride: _flowChipOverride(snap.data),
                            onSend: (t) {
                              unawaited(_sendMessageWithText(t));
                            },
                          );
                        },
                      ),
                      _buildInputRow(),
                    ],
                  ),
                ),
              ),
            ],
          );

          final backdrop = Stack(
            fit: StackFit.expand,
            children: [
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF0A0A0F), Color(0xFF121826)],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 48,
                left: -24,
                right: -24,
                height: 320,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0.55, -0.15),
                        radius: 1.05,
                        colors: [
                          const Color(0xFF6366F1).withValues(alpha: 0.26),
                          const Color(0xFF2563EB).withValues(alpha: 0.12),
                          const Color(0xFF0A0A0F).withValues(alpha: 0),
                        ],
                        stops: const [0.0, 0.35, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              chatColumn,
            ],
          );

          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 280, child: sidebar),
                Expanded(child: backdrop),
              ],
            );
          }

          return Scaffold(
            key: _narrowScaffoldKey,
            backgroundColor: Colors.transparent,
            drawer: Drawer(
              width: math.min(288.0, constraints.maxWidth * 0.88),
              backgroundColor: const Color(0xFF0F1117),
              child: sidebar,
            ),
            appBar: AppBar(
              backgroundColor: const Color(0xFF0A0A0F).withValues(alpha: 0.94),
              surfaceTintColor: Colors.transparent,
              foregroundColor: const Color(0xFFE2E8F0),
              elevation: 0,
              title: const Text('Aivy Chat'),
              leading: IconButton(
                icon: const Icon(Icons.menu_rounded),
                tooltip: 'Chats',
                onPressed: () =>
                    _narrowScaffoldKey.currentState?.openDrawer(),
              ),
            ),
            body: backdrop,
          );
        },
      ),
    );
  }

  Widget _buildDictationStrip() {
    const r = 20.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(r),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(r),
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF0C0D14).withValues(alpha: 0.78),
                  const Color(0xFF121826).withValues(alpha: 0.62),
                ],
              ),
              border: Border.all(
                color: const Color(0xFF22D3EE).withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_handsFreeListening)
                  _VoiceLevelSpikeStrip(level: _handsFreeLastDb)
                else
                  const _PulsingRecordDot(color: Color(0xFF22D3EE)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _handsFreeListening
                            ? 'Listening — auto send when you pause'
                            : _holdUsesCloudRecorder
                                ? 'Recording — release to send'
                                : 'Listening…',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: const Color(0xFF94A3B8),
                              letterSpacing: 0.3,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _handsFreeListening
                            ? 'Hindi + English · Google Cloud'
                            : _holdUsesCloudRecorder
                                ? _formatVoiceHoldDuration()
                                : (_liveTranscript.isEmpty
                                    ? '—'
                                    : _liveTranscript),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: const Color(0xFFE2E8F0),
                              fontWeight: FontWeight.w500,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInputRow() {
    return AiInputBar(
      controller: _textController,
      focusNode: _inputFocus,
      enabled: !_isSending && !_controlledFlow.confirmSaveBusy.value,
      hintText: 'Type anything: meeting notes, reminders, tasks...',
      onSend: () {
        if (_isSending) {
          return;
        }
        if (_hasText) {
          _sendMessage();
        }
      },
      onMicDown: _onMicDown,
      onMicUp: _onMicUp,
      onHandsFreeTap: kIsWeb ? null : _toggleHandsFreeVoice,
      handsFreeListening: _handsFreeListening,
    );
  }
}

/// Animated mini spectrum driven by microphone dB (hands-free mode).
class _VoiceLevelSpikeStrip extends StatelessWidget {
  const _VoiceLevelSpikeStrip({required this.level});

  /// Current amplitude in dB from the `record` plugin (typical speech: -25…-45).
  final double level;

  @override
  Widget build(BuildContext context) {
    final n = ((level + 48).clamp(0.0, 48.0) / 48.0);
    return SizedBox(
      width: 40,
      height: 28,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(5, (i) {
          final jitter = 0.5 + 0.16 * ((i * 3) % 5);
          final h = 5.0 + (20.0 * n * jitter);
          return Padding(
            padding: const EdgeInsets.only(right: 3),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              width: 4,
              height: h.clamp(4.0, 26.0),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: const LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xFF22D3EE), Color(0xFFA78BFA)],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// A tiny dot that breathes in/out for live dictation or recording UIs.
class _PulsingRecordDot extends StatefulWidget {
  const _PulsingRecordDot({required this.color});

  final Color color;

  @override
  State<_PulsingRecordDot> createState() => _PulsingRecordDotState();
}

class _PulsingRecordDotState extends State<_PulsingRecordDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1.0).animate(_controller),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
