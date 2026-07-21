import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

import '../../../core/voice/google_voice_service.dart';
import 'assistant_google_voice_completion.dart';
import 'controlled_chat_flow.dart';
import '../data/aivy_process_service.dart';
import '../data/chat_repository.dart';
import '../models/aivy_ai_response.dart';
import '../utils/aivy_response_formatter.dart';
import '../utils/intent_detection.dart';
import '../utils/smart_command_expand.dart';
import '../../reminders/utils/reminder_context_parser.dart';

/// Shared text-message routing used by [ChatScreen] and the Home dashboard.
/// Business data is no longer saved from this layer — only greeting shortcuts
/// and cloud [AivyProcessService] responses (chat copy only; see repository).
class UserTextPipeline {
  UserTextPipeline({
    required this.userId,
    required this.chatId,
    required ChatRepository repository,
    required AivyProcessService aivyProcessService,
    GoogleVoiceService? googleVoice,
  }) : _repository = repository,
       _aivyProcessService = aivyProcessService,
       _googleVoice = googleVoice;

  final String userId;
  final String chatId;
  final ChatRepository _repository;
  final AivyProcessService _aivyProcessService;
  final GoogleVoiceService? _googleVoice;

  /// Prefer server [AivyAiResponse.transcript] for intent; if missing, use structured fields
  /// (never user-facing cloud prose). Used by the voice pipeline.
  static String intentRoutingText(AivyAiResponse response) {
    final tr = response.transcript?.trim() ?? '';
    if (tr.isNotEmpty) {
      return tr;
    }
    final s = response.summary.trim();
    if (s.isNotEmpty) {
      return s;
    }
    return '';
  }

  Future<void> processUserMessage(String text, String entryId) async {
    if (await _tryGreetingIntent(text, entryId)) {
      return;
    }
    final flow = await _repository.fetchChatFlowState(userId);
    if (ControlledChatFlow.isControlledFlowBlockingGenericAi(flow)) {
      if (kDebugMode) {
        debugPrint(
          '[AIVY_ROUTE] cloud_blocked pa=${flow.pendingAction} '
          'cat=${flow.currentCategory} sub=${flow.currentSubcategory} '
          'step=${flow.stepIndex} text="${text.trim()}"',
        );
      }
      await _repository.completeEntryWithLocalAssistantOnly(
        userId: userId,
        chatId: chatId,
        entryId: entryId,
        assistantText:
            'Abhi flow chal raha hai — jo sawaal pucha gaya hai usi ka jawab dijiye. '
            'Payment receive date ke liye: aaj, kal, parso, 5 May, ya dd/mm/yyyy.',
        contextType: 'controlled_flow_guard',
      );
      return;
    }
    final intent = detectIntent(text);
    _logRouteIntent(text, intent);

    final agentText = expandSmartCommandInput(text) ?? text;
    if (kDebugMode) {
      debugPrint(
        '[AIVY_TRACE_CONFIRM] UserTextPipeline → _callAivyProcess (cloud)',
      );
    }
    await _callAivyProcess(agentText, entryId, routedIntent: intent);
  }

  void _logRouteIntent(String text, AivyUserIntent intent) {
    if (intent == AivyUserIntent.reminder) {
      final p = ReminderContextParser.parse(text);
      logAivyIntentDebug(text, intent, parsed: {
        'title': p.title,
        'client': p.client,
        'action': p.action,
        'description': p.description ?? '',
      });
    } else {
      logAivyIntentDebug(text, intent);
    }
  }

  Future<bool> _tryGreetingIntent(String text, String entryId) async {
    final t = text.trim();
    final lower = t.toLowerCase();
    if (t.length > 12) {
      return false;
    }
    final isGreeting =
        RegExp(r'^(hi|hello|hey)\b', caseSensitive: false).hasMatch(lower);
    if (!isGreeting) {
      return false;
    }
    await _repository.completeEntryWithLocalAssistantOnly(
      userId: userId,
      chatId: chatId,
      entryId: entryId,
      assistantText: generateAivyResponse('greeting', const {}),
      contextType: 'local_greeting',
    );
    return true;
  }

  Future<void> _callAivyProcess(
    String text,
    String entryId, {
    AivyUserIntent? routedIntent,
  }) async {
    final aiResponse = await _aivyProcessService.analyzeInput(
      text,
      clientIntent: routedIntent?.name,
    );
    final ttsUrl = await AssistantGoogleVoiceCompletion.maybeSynthesizeTtsUrl(
      voice: _googleVoice,
      response: aiResponse,
    );
    await _repository.completeEntryWithAgentActivation(
      userId: userId,
      chatId: chatId,
      entryId: entryId,
      response: aiResponse,
      userRawInput: text,
      assistantTtsUrl: ttsUrl,
    );
  }
}
