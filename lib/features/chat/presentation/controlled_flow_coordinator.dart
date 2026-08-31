import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/voice/google_voice_service.dart';
import '../application/assistant_google_voice_completion.dart';
import '../application/controlled_chat_flow.dart';
import '../application/flow_catalog.dart';
import '../application/flow_formatters.dart';
import '../application/flow_step_engine.dart';
import '../data/aivy_process_service.dart';
import '../data/chat_flow_state.dart';
import '../data/chat_repository.dart';
import '../models/chat_message.dart';
import '../../projects/application/project_cloud_confirm.dart';
import 'widgets/category_selector_bottom_sheet.dart';
import 'widgets/subcategory_selector_bottom_sheet.dart';

/// Handles [ProcessResult] from [ControlledChatFlow] — sheets, save, cloud.
class ControlledFlowCoordinator {
  const ControlledFlowCoordinator._();

  static Future<void> apply({
    required BuildContext context,
    required ProcessResult result,
    required String userId,
    required String chatId,
    required String entryId,
    required ChatRepository repository,
    required ControlledChatFlow flow,
    required AivyProcessService aivy,
    GoogleVoiceService? googleVoice,
  }) async {
    // ignore: avoid_print
    if (kDebugMode) {
      // ignore: avoid_print
      print(
        'AIVY_CTRL apply kind=${result.kind} '
        'confirmDraftNull=${result.confirmDraft == null} '
        'confirmMapKeys=${result.confirmDraftMap?.keys.toList()} '
        'assistantChars=${result.assistantMessage?.length ?? 0}',
      );
      debugPrint(
        '[AIVY_TRACE_CONFIRM] ControlledFlowCoordinator.apply ENTER '
        'kind=${result.kind} confirmDraftNull=${result.confirmDraft == null}',
      );
    }
    switch (result.kind) {
      case ProcessKind.none:
        return;
      case ProcessKind.assistantOnly:
        final msg = result.assistantMessage?.trim() ?? '';
        if (msg.isEmpty) {
          return;
        }
        await repository.completeEntryWithLocalAssistantOnly(
          userId: userId,
          chatId: chatId,
          entryId: entryId,
          assistantText: msg,
          contextType: 'controlled_flow',
          aivyData: result.aivyData,
        );
        return;
      case ProcessKind.openCategorySheet:
        final intro = result.assistantMessage?.trim() ?? getGreeting();
        await repository.completeEntryWithLocalAssistantOnly(
          userId: userId,
          chatId: chatId,
          entryId: entryId,
          assistantText: intro,
          contextType: 'controlled_flow',
        );
        if (!context.mounted) {
          return;
        }
        final cat = await showCategorySelector(context);
        if (!context.mounted) {
          return;
        }
        if (cat == null) {
          await flow.stateService.clearState(userId);
          return;
        }
        await flow.stateService.updateState(
          userId,
          ChatFlowState(
            currentCategory: cat.id,
            pendingAction: ChatFlowState.actionSelectingSub,
            stepIndex: 0,
            pendingData: const {},
          ),
        );
        if (!context.mounted) {
          return;
        }
        final sub = await showSubcategorySelector(
          context,
          categoryId: cat.id,
        );
        if (!context.mounted) {
          return;
        }
        if (sub == null) {
          await flow.stateService.clearState(userId);
          return;
        }
        if (cat.id == 'payment' && sub.id == 'received') {
          await flow.stateService.updateState(
            userId,
            ChatFlowState(
              currentCategory: cat.id,
              currentSubcategory: sub.id,
              flowCategoryId: flowCategoryIdFor(cat.id, sub.id),
              pendingAction: ChatFlowState.actionAwaitingPaymentReceivedChoice,
              stepIndex: 0,
              pendingData: const {},
            ),
          );
          await repository.addMessage(
            userId: userId,
            chatId: chatId,
            role: ChatRole.assistant,
            text:
                'Kaise proceed karna hai?\n\n'
                '1. Client ka naam likhunga\n'
                '2. Pending clients ki list dikhao',
          );
          return;
        }
        final keys = fieldKeysFor(cat.id, sub.id);
        if (keys.isEmpty) {
          await flow.stateService.clearState(userId);
          return;
        }
        if (cat.id == 'payment' && sub.id == 'due') {
          await flow.stateService.updateState(
            userId,
            ChatFlowState(
              currentCategory: cat.id,
              currentSubcategory: sub.id,
              flowCategoryId: flowCategoryIdFor(cat.id, sub.id),
              pendingAction: ChatFlowState.actionAwaitingPaymentDueChoice,
              stepIndex: 0,
              pendingData: const {},
            ),
          );
          const first =
              '💰 Kya karna hai?\n\n'
              '1. Saari pending payment ki list (amount + due date)\n'
              '2. Sirf ek client ki list — pehle 2 bhejein, phir client ka naam\n\n'
              'Naya due / amount jodna ho to: Payment → Follow-up → Payment follow-up.\n\n'
              'Ya seedha client ka naam bhi likh sakte hain (uski pending list ke liye).';
          await repository.addMessage(
            userId: userId,
            chatId: chatId,
            role: ChatRole.assistant,
            text: first,
          );
          return;
        }
        if (cat.id == 'payment' && sub.id == 'followup') {
          await flow.stateService.updateState(
            userId,
            ChatFlowState(
              currentCategory: cat.id,
              currentSubcategory: sub.id,
              flowCategoryId: flowCategoryIdFor(cat.id, sub.id),
              pendingAction: ChatFlowState.actionAwaitingPaymentFollowupChoice,
              stepIndex: 0,
              pendingData: const {},
            ),
          );
          const first =
              '💰 Naya payment follow-up add karna hai?\n\n'
              '1. Client list se chunein (existing client)\n'
              '2. Naya client add karein\n\n'
              'Number bhejein (1 ya 2).';
          await repository.addMessage(
            userId: userId,
            chatId: chatId,
            role: ChatRole.assistant,
            text: first,
          );
          return;
        }
        if (cat.id == 'order' && sub.id == 'update') {
          await flow.stateService.updateState(
            userId,
            ChatFlowState(
              currentCategory: cat.id,
              currentSubcategory: sub.id,
              flowCategoryId: flowCategoryIdFor(cat.id, sub.id),
              pendingAction: ChatFlowState.actionAwaitingOrderUpdateMode,
              stepIndex: 0,
              pendingData: const {},
            ),
          );
          await repository.addMessage(
            userId: userId,
            chatId: chatId,
            role: ChatRole.assistant,
            text:
                'Order update mode:\n\n'
                '1. Process\n'
                '2. Dispatch\n\n'
                'Number bhejein (1 ya 2).',
          );
          return;
        }
        if (cat.id == 'quotation' && sub.id == 'followup') {
          final recent = await repository.fetchRecentQuotations(
            userId,
            days: 30,
            limit: 50,
          );
          if (recent.isEmpty) {
            await flow.stateService.clearState(userId);
            await repository.addMessage(
              userId: userId,
              chatId: chatId,
              role: ChatRole.assistant,
              text:
                  'Last 30 days me koi quotation nahi mila. Pehle New quotation save karein.',
            );
            return;
          }
          final fmt = DateFormat('d MMM');
          final rows = <Map<String, dynamic>>[];
          final buf = StringBuffer(
            'Last 30 days ke quotations:\n\nKaunse quotation ka follow-up set karna hai?\n',
          );
          for (var i = 0; i < recent.length; i++) {
            final q = recent[i];
            final client = (q.clientName ?? 'Client').trim();
            final dt = q.createdAtMs > 0
                ? fmt.format(DateTime.fromMillisecondsSinceEpoch(q.createdAtMs))
                : '—';
            final followUp = q.followUpDateMs > 0
                ? DateFormat(
                    'd MMM, hh:mm a',
                  ).format(DateTime.fromMillisecondsSinceEpoch(q.followUpDateMs))
                : '—';
            buf.writeln(
              '${i + 1}. $client — ₹${q.amount.toStringAsFixed(0)} '
              '(created $dt, follow-up $followUp)',
            );
            rows.add({
              'quotationId': q.id,
              'name': client,
              'amount': q.amount,
              'createdAtMs': q.createdAtMs,
              'followUpDateMs': q.followUpDateMs,
            });
          }
          buf.write('\nNumber bhejein (1-${recent.length}).');
          await flow.stateService.updateState(
            userId,
            ChatFlowState(
              currentCategory: cat.id,
              currentSubcategory: sub.id,
              flowCategoryId: flowCategoryIdFor(cat.id, sub.id),
              pendingAction: ChatFlowState.actionPendingSelection,
              selectionType: ChatFlowState.selectionQuotationFollowupPick,
              selectionList: rows,
              pendingSelection: true,
              stepIndex: 0,
              pendingData: const {},
            ),
          );
          await repository.addMessage(
            userId: userId,
            chatId: chatId,
            role: ChatRole.assistant,
            text: buf.toString().trim(),
          );
          return;
        }
        final init = FlowStepEngine.initialPendingData(cat.id, sub.id);
        await flow.stateService.updateState(
          userId,
          ChatFlowState(
            currentCategory: cat.id,
            currentSubcategory: sub.id,
            flowCategoryId: flowCategoryIdFor(cat.id, sub.id),
            pendingAction: ChatFlowState.actionCollecting,
            stepIndex: 0,
            pendingData: init,
          ),
        );
        final first = FlowStepEngine.getNextQuestion(0, cat.id, sub.id);
        await repository.addMessage(
          userId: userId,
          chatId: chatId,
          role: ChatRole.assistant,
          text: first,
        );
        return;
      case ProcessKind.inChatConfirm:
      case ProcessKind.openConfirmDialog:
        if (kDebugMode) {
          debugPrint(
            '[AIVY_TRACE_CONFIRM] coordinator inChatConfirm branch '
            'confirmDraftNull=${result.confirmDraft == null}',
          );
        }
        final draft = result.confirmDraft;
        if (draft == null) {
          if (kDebugMode) {
            debugPrint(
              '[AIVY_TRACE_CONFIRM] coordinator EARLY EXIT inChatConfirm (draft null)',
            );
          }
          return;
        }
        final confirmDraftMap = result.confirmDraftMap ??
            ControlledChatFlow.buildConfirmDraftMap(
              draft,
              flowCategoryId: flowCategoryIdFromActionTypes(draft.type, draft.subType),
            );
        final summary = result.assistantMessage?.trim().isNotEmpty == true
            ? result.assistantMessage!.trim()
            : formatConfirmSummary(confirmDraftMap, draft);
        await flow.stateService.clearState(userId);
        await flow.stateService.updateState(
          userId,
          ChatFlowState(
            pendingAction: ChatFlowState.actionAwaitingChatConfirm,
            stepIndex: 0,
            pendingData: {
              'confirmDraft': confirmDraftMap,
            },
          ),
        );
        await repository.completeEntryWithLocalAssistantOnly(
          userId: userId,
          chatId: chatId,
          entryId: entryId,
          assistantText: summary,
          contextType: 'controlled_flow',
          aivyData: result.aivyData,
        );
        if (kDebugMode) {
          debugPrint(
            '[AIVY_TRACE_CONFIRM] coordinator inChatConfirm DONE '
            '(state updated + completeEntryWithLocalAssistantOnly)',
          );
        }
        return;
      case ProcessKind.disambiguation:
        final msg =
            (result.disambiguationLine ?? result.assistantMessage)?.trim() ?? '';
        if (msg.isEmpty) {
          return;
        }
        await repository.completeEntryWithLocalAssistantOnly(
          userId: userId,
          chatId: chatId,
          entryId: entryId,
          assistantText: msg,
          contextType: 'controlled_flow',
        );
        return;
      case ProcessKind.cloud:
        final text = result.cloudText?.trim() ?? '';
        if (text.isEmpty) {
          await repository.completeEntryWithLocalAssistantOnly(
            userId: userId,
            chatId: chatId,
            entryId: entryId,
            assistantText: 'Kuch type karein pehle.',
            contextType: 'controlled_flow',
          );
          return;
        }
        final ci = result.cloudIntent?.trim();
        final ai = await aivy.analyzeInput(
          text,
          clientIntent: ci == null || ci.isEmpty ? null : ci,
        );
        final applied = await ProjectCloudConfirm.tryApply(
          ai: ai,
          userId: userId,
          chatId: chatId,
          entryId: entryId,
          repository: repository,
          state: flow.stateService,
        );
        if (applied) {
          return;
        }
        final ttsUrl = await AssistantGoogleVoiceCompletion.maybeSynthesizeTtsUrl(
          voice: googleVoice,
          response: ai,
        );
        await repository.completeEntryWithAgentActivation(
          userId: userId,
          chatId: chatId,
          entryId: entryId,
          response: ai,
          userRawInput: text,
          assistantTtsUrl: ttsUrl,
        );
        return;
    }
  }
}
