import '../../chat/data/chat_repository.dart';
import '../models/agent_insights.dart';

/// Runs the one-shot "proactive nudge" pass when the app boots.
///
/// The dashboard also re-computes insights from its live streams, but doing
/// an explicit fetch at launch gives us a deterministic snapshot we can act
/// on (banners, snackbars, log analytics, etc.) without waiting for
/// Firestore snapshot listeners to warm up.
class AgentNudgeService {
  AgentNudgeService({ChatRepository? repository})
    : _repository = repository ?? ChatRepository();

  final ChatRepository _repository;

  /// Fetches pending tasks and overdue reminders for [userId] and reduces
  /// them into an [AgentInsights] snapshot.
  Future<AgentInsights> generateLaunchInsights(String userId) async {
    final pendingTasksFuture = _repository.fetchPendingTasks(userId);
    final overdueRemindersFuture = _repository.fetchOverdueReminders(userId);

    final pendingTasks = await pendingTasksFuture;
    final overdueReminders = await overdueRemindersFuture;

    return AgentInsights.fromData(
      pendingTasks: pendingTasks,
      overdueReminders: overdueReminders,
    );
  }
}
