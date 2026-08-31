import '../../chat/data/chat_flow_state.dart';
import '../../chat/data/chat_repository.dart';
import '../../chat/data/chat_state_service.dart';
import '../../chat/models/aivy_ai_response.dart';
import '../utils/project_confirm.dart';

/// Turns a `project_extract` cloud reply into the same in-chat Confirm card
/// used by payment / reminder flows.
class ProjectCloudConfirm {
  const ProjectCloudConfirm._();

  static bool hasExtract(AivyAiResponse ai) {
    final d = ai.projectDraft;
    if (d == null) {
      return false;
    }
    final items = d['items'];
    return items is List && items.isNotEmpty;
  }

  static Future<bool> tryApply({
    required AivyAiResponse ai,
    required String userId,
    required String chatId,
    required String entryId,
    required ChatRepository repository,
    required ChatStateService state,
  }) async {
    if (!hasExtract(ai)) {
      return false;
    }
    final map = projectDraftToConfirmMap(ai.projectDraft!);
    final summary = ai.assistantReply.trim().isNotEmpty
        ? ai.assistantReply.trim()
        : formatProjectConfirmSummary(map);
    await state.clearState(userId);
    await state.updateState(
      userId,
      ChatFlowState(
        pendingAction: ChatFlowState.actionAwaitingChatConfirm,
        stepIndex: 0,
        pendingData: {'confirmDraft': map},
      ),
    );
    await repository.completeEntryWithLocalAssistantOnly(
      userId: userId,
      chatId: chatId,
      entryId: entryId,
      assistantText: summary,
      contextType: 'controlled_flow',
      aivyData: {
        'quickReplies': ['Confirm', 'Edit', 'Cancel'],
        'controlledFlow': true,
        'projectDraft': true,
        'items': map['items'],
        'projectName': map['projectName'],
        'client': map['client'],
      },
    );
    return true;
  }
}
