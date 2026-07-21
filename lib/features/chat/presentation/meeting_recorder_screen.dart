import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode, debugPrint;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/speech/dictation_text.dart';
import '../../../core/speech/local_speech_to_text.dart';
import '../data/aivy_process_service.dart';
import '../data/chat_repository.dart';
import '../models/aivy_ai_response.dart';
import '../models/chat_message.dart';
import '../utils/aivy_response_formatter.dart';

class MeetingRecorderScreen extends StatefulWidget {
  const MeetingRecorderScreen({
    super.key,
    required this.userId,
    required this.activeChatId,
  });

  final String userId;
  final String activeChatId;

  @override
  State<MeetingRecorderScreen> createState() => _MeetingRecorderScreenState();
}

class _MeetingRecorderScreenState extends State<MeetingRecorderScreen> {
  late final ChatRepository _repository;
  late final AivyProcessService _aivyProcessService;
  final LocalSpeechToText _localSpeech = LocalSpeechToText();

  bool _isListening = false;
  bool _isProcessing = false;
  bool _holdSession = false;
  DateTime? _sessionStartedAt;
  Timer? _sessionTicker;
  int _lastDurationMs = 0;
  String _liveTranscript = '';
  AivyAiResponse? _latestResponse;

  @override
  void initState() {
    super.initState();
    _repository = ChatRepository();
    _aivyProcessService = AivyProcessService();
  }

  @override
  void dispose() {
    _sessionTicker?.cancel();
    if (_localSpeech.isListening) {
      unawaited(_localSpeech.stop());
    }
    _aivyProcessService.dispose();
    super.dispose();
  }

  int get _sessionElapsedMs {
    final start = _sessionStartedAt;
    if (start == null) {
      return 0;
    }
    return DateTime.now().difference(start).inMilliseconds;
  }

  String _formatDuration(int durationMs) {
    final totalSec = durationMs ~/ 1000;
    final minutes = totalSec ~/ 60;
    final seconds = totalSec % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String _describeMeetingError(Object error) {
    final raw = error.toString();
    final lowered = raw.toLowerCase();
    if (lowered.contains('transcription')) {
      return 'We could not process this meeting. Please try again.';
    }
    if (lowered.contains('unauthenticated')) {
      return 'Your session expired. Please sign in again and retry.';
    }
    if (lowered.contains('failed-precondition') ||
        lowered.contains('missing openai') ||
        lowered.contains('missing mistral')) {
      return 'Aivy is not fully configured on the server. Please contact support.';
    }
    if (kDebugMode) {
      return 'Could not process meeting: $raw';
    }
    return 'Could not process meeting. Please try again.';
  }

  Future<void> _startListening() async {
    if (_isProcessing || _isListening) {
      return;
    }
    if (kIsWeb) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Meeting dictation is not available on web.'),
        ),
      );
      return;
    }

    _holdSession = true;
    _liveTranscript = '';

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      _holdSession = false;
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Microphone permission is required to dictate.'),
          action: status.isPermanentlyDenied
              ? SnackBarAction(label: 'Settings', onPressed: openAppSettings)
              : null,
        ),
      );
      return;
    }

    if (!_holdSession) {
      return;
    }

    final ok = await _localSpeech.initialize();
    if (!_holdSession) {
      if (_localSpeech.isListening) {
        await _localSpeech.stop();
      }
      return;
    }
    if (!ok) {
      _holdSession = false;
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
      _isListening = true;
      _sessionStartedAt = DateTime.now();
      _lastDurationMs = 0;
      _liveTranscript = '';
    });

    _sessionTicker?.cancel();
    _sessionTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) {
        setState(() {});
      }
    });

    try {
      var committedPrefix = '';
      var firstSegment = true;
      while (_holdSession && mounted) {
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
        debugPrint('[MeetingRecorder] listen error: $e');
      }
      if (mounted) {
        setState(() {
          _isListening = false;
          _sessionStartedAt = null;
        });
        _sessionTicker?.cancel();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Speech recognition failed: $e')),
        );
      }
      return;
    }

    if (!_holdSession && _localSpeech.isListening) {
      await _localSpeech.stop();
    }
  }

  Future<void> _stopListeningAndAnalyze() async {
    if (!_isListening) {
      return;
    }

    _holdSession = false;
    final durationMs = _sessionElapsedMs;
    _sessionTicker?.cancel();
    _sessionTicker = null;
    _sessionStartedAt = null;

    await _localSpeech.stop();

    final transcript = _liveTranscript.trim();
    if (!mounted) {
      return;
    }
    setState(() {
      _isListening = false;
    });

    if (transcript.isEmpty) {
      if (mounted) {
        setState(() => _liveTranscript = '');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No speech was recognized. Try again and speak clearly.'),
          ),
        );
      }
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _isProcessing = true;
      _lastDurationMs = durationMs;
    });

    String? entryId;
    try {
      entryId = await _repository.createEntry(
        userId: widget.userId,
        rawInput: transcript,
        source: 'meeting',
      );

      await _repository.addMessage(
        userId: widget.userId,
        chatId: widget.activeChatId,
        role: ChatRole.user,
        text: transcript.length > 800 ? '${transcript.substring(0, 800)}…' : transcript,
        entryId: entryId,
        type: ChatMessageType.text,
        durationMs: durationMs,
      );

      final aiResponse =
          await _aivyProcessService.analyzeMeetingTranscript(transcript);

      await _repository.completeEntryWithAgentActivation(
        userId: widget.userId,
        chatId: widget.activeChatId,
        entryId: entryId,
        response: aiResponse,
        userRawInput: aiResponse.transcript?.trim().isNotEmpty == true
            ? aiResponse.transcript
            : transcript,
      );

      final preview = transcript.length > 200
          ? '${transcript.substring(0, 200)}…'
          : transcript;
      await _repository.saveMeetingSession(
        userId: widget.userId,
        entryId: entryId,
        chatId: widget.activeChatId,
        durationMs: durationMs,
        transcriptPreview: preview,
        summary: aiResponse.summary,
      );

      if (!mounted) {
        return;
      }
      setState(() {
        _latestResponse = aiResponse;
        _liveTranscript = '';
      });
    } catch (error) {
      if (entryId != null) {
        await _repository.failEntry(
          userId: widget.userId,
          entryId: entryId,
          reason: error.toString(),
        );
        await _repository.addMessage(
          userId: widget.userId,
          chatId: widget.activeChatId,
          role: ChatRole.assistant,
          text: generateAivyResponse('error', const {}),
          entryId: entryId,
          isError: true,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_describeMeetingError(error))));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final response = _latestResponse;
    final colorScheme = Theme.of(context).colorScheme;
    final sessionTime = _isListening
        ? _formatDuration(_sessionElapsedMs)
        : _formatDuration(_lastDurationMs);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Meeting Recorder'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Capture meeting',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Use your device’s speech recognition to take notes in real time. '
                    'When you stop, Aivy turns the transcript into a summary, key points, and tasks.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(
                        Icons.timer_outlined,
                        color: _isListening
                            ? colorScheme.error
                            : colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        sessionTime,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      if (_isListening)
                        FilledButton.icon(
                          onPressed: _stopListeningAndAnalyze,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('Stop & analyze'),
                        )
                      else
                        FilledButton.tonalIcon(
                          onPressed: _isProcessing ? null : _startListening,
                          icon: const Icon(Icons.mic),
                          label: const Text('Start dictation'),
                        ),
                    ],
                  ),
                  if (_isProcessing) ...[
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Processing meeting with Aivy...',
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(12)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                    border: Border.all(
                      color: _isListening
                          ? const Color(0xFF22D3EE).withValues(alpha: 0.28)
                          : colorScheme.outlineVariant.withValues(alpha: 0.4),
                    ),
                    gradient: LinearGradient(
                      colors: [
                        colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        colorScheme.surfaceContainerLow
                            .withValues(alpha: 0.3),
                      ],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isListening ? 'Live transcript' : 'Transcript',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: const Color(0xFF94A3B8),
                              letterSpacing: 0.4,
                            ),
                      ),
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: 120,
                          maxHeight: 280,
                        ),
                        child: Scrollbar(
                          child: SingleChildScrollView(
                            child: Text(
                              _liveTranscript.isEmpty && !_isListening
                                  ? 'Start dictation to see your words appear here, like the chat input.'
                                  : _liveTranscript.isEmpty
                                      ? 'Listening…'
                                      : _liveTranscript,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyLarge
                                  ?.copyWith(
                                    height: 1.4,
                                    fontWeight: FontWeight.w500,
                                  ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: response == null
                  ? const Text(
                      'No result yet. Dictate a meeting, then stop & analyze to see Aivy’s summary.',
                    )
                  : _MeetingResultView(response: response),
            ),
          ),
        ],
      ),
    );
  }
}

class _MeetingResultView extends StatelessWidget {
  const _MeetingResultView({required this.response});

  final AivyAiResponse response;

  @override
  Widget build(BuildContext context) {
    final summary = response.summary.trim();
    final keyPoints = response.keyPoints;
    final actionItems = response.actionItems;
    final createdCount = response.createdTaskIds.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (summary.isNotEmpty) ...[
          Text('Summary', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(summary),
          const SizedBox(height: 14),
        ],
        if (keyPoints.isNotEmpty) ...[
          Text('Key Points', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          for (final point in keyPoints) Text('• $point'),
          const SizedBox(height: 14),
        ],
        if (actionItems.isNotEmpty) ...[
          Text('Action Items', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          for (final item in actionItems) Text('• $item'),
          const SizedBox(height: 14),
        ],
        if (createdCount > 0)
          Text(
            '$createdCount tasks were added to your task list.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        if (summary.isEmpty && keyPoints.isEmpty && actionItems.isEmpty)
          Text(userReplyOnlyForChat(response)),
      ],
    );
  }
}
