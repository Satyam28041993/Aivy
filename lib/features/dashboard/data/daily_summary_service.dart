import 'package:intl/intl.dart';

import '../../chat/data/aivy_process_service.dart';
import '../../chat/data/chat_repository.dart';
import '../../chat/utils/aivy_response_formatter.dart';
import '../../reminders/models/reminder_item.dart';
import '../../tasks/models/task_item.dart';
import '../models/daily_summary.dart';

/// Aggregates today's tasks, overdue tasks, and upcoming reminders, asks the
/// Aivy backend to "Generate today's plan", and persists the result under
/// `users/{uid}/daily_summary/{yyyy-MM-dd}`.
///
/// The dashboard calls [generateForToday] from the "Today's Focus" card and
/// listens to [ChatRepository.watchDailySummary] for live updates.
class DailySummaryService {
  DailySummaryService({
    ChatRepository? repository,
    AivyProcessService? processService,
  }) : _repository = repository ?? ChatRepository(),
       _processService = processService ?? AivyProcessService();

  final ChatRepository _repository;
  final AivyProcessService _processService;

  /// Kicks the whole pipeline:
  /// 1. Pulls pending tasks + upcoming reminders.
  /// 2. Splits them into "today", "overdue", "upcoming".
  /// 3. Sends a structured "Generate today's plan" prompt to `aivyProcess`.
  /// 4. Writes the response to Firestore.
  ///
  /// Returns the saved [DailySummary].
  Future<DailySummary> generateForToday(String userId) async {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    final startOfTomorrow = startOfToday.add(const Duration(days: 1));

    final pendingTasks = await _repository.fetchPendingTasks(userId);
    final upcomingReminders = await _fetchUpcomingReminders(userId);

    final todaysTasks = pendingTasks
        .where((task) {
          final due = task.dueDateMs;
          if (due == null) {
            return false;
          }
          final dueDate = DateTime.fromMillisecondsSinceEpoch(due);
          return !dueDate.isBefore(startOfToday) &&
              dueDate.isBefore(startOfTomorrow);
        })
        .toList(growable: false);

    final overdueTasks = pendingTasks
        .where((task) {
          final due = task.dueDateMs;
          if (due == null) {
            return false;
          }
          return DateTime.fromMillisecondsSinceEpoch(
            due,
          ).isBefore(startOfToday);
        })
        .toList(growable: false);

    final prompt = _buildPrompt(
      now: now,
      todaysTasks: todaysTasks,
      overdueTasks: overdueTasks,
      upcomingReminders: upcomingReminders,
    );

    final response = await _processService.analyzeInput(prompt);

    // Prefer the AI's bulleted keyPoints. If the model skipped them we fall
    // back to action items so the UI always has something to render.
    final bullets = response.keyPoints.isNotEmpty
        ? response.keyPoints
        : response.actionItems;

    final assistantUi = formatCloudAssistantReply(
      response,
      userRawInput: prompt,
    );

    await _repository.saveDailySummary(
      userId: userId,
      date: now,
      summary: response.summary,
      bulletPoints: bullets,
      assistantReply: assistantUi,
      todayTaskCount: todaysTasks.length,
      overdueTaskCount: overdueTasks.length,
      upcomingReminderCount: upcomingReminders.length,
    );

    return DailySummary(
      date: DailySummary.dateKey(now),
      summary: response.summary,
      bulletPoints: bullets,
      assistantReply: assistantUi,
      generatedAtMs: DateTime.now().millisecondsSinceEpoch,
      todayTaskCount: todaysTasks.length,
      overdueTaskCount: overdueTasks.length,
      upcomingReminderCount: upcomingReminders.length,
    );
  }

  Future<List<ReminderItem>> _fetchUpcomingReminders(String userId) async {
    final reminders = await _repository
        .watchUpcomingReminders(userId)
        .first
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => const <ReminderItem>[],
        );
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return reminders
        .where((item) => item.scheduledTimeMs >= nowMs)
        .toList(growable: false);
  }

  String _buildPrompt({
    required DateTime now,
    required List<TaskItem> todaysTasks,
    required List<TaskItem> overdueTasks,
    required List<ReminderItem> upcomingReminders,
  }) {
    final dateFormat = DateFormat('EEEE, d MMMM yyyy');
    final timeFormat = DateFormat('hh:mm a');

    final buffer = StringBuffer()
      ..writeln("Generate today's plan")
      ..writeln()
      ..writeln('Date: ${dateFormat.format(now)}')
      ..writeln();

    buffer.writeln("Today's tasks (${todaysTasks.length}):");
    if (todaysTasks.isEmpty) {
      buffer.writeln('- none');
    } else {
      for (final task in todaysTasks) {
        buffer.writeln('- ${_taskLine(task, timeFormat)}');
      }
    }
    buffer.writeln();

    buffer.writeln('Overdue tasks (${overdueTasks.length}):');
    if (overdueTasks.isEmpty) {
      buffer.writeln('- none');
    } else {
      for (final task in overdueTasks) {
        buffer.writeln('- ${_taskLine(task, dateFormat)}');
      }
    }
    buffer.writeln();

    buffer.writeln('Upcoming reminders (${upcomingReminders.length}):');
    if (upcomingReminders.isEmpty) {
      buffer.writeln('- none');
    } else {
      for (final reminder in upcomingReminders.take(10)) {
        final when = DateTime.fromMillisecondsSinceEpoch(
          reminder.scheduledTimeMs,
        );
        buffer.writeln(
          '- ${reminder.displayTitle} (${DateFormat('EEE hh:mm a').format(when)})',
        );
      }
    }
    buffer.writeln();

    buffer.writeln(
      'Respond with a short plan for today as bullet points in keyPoints, '
      'ordered by urgency. Call out anything overdue first.',
    );

    return buffer.toString().trim();
  }

  String _taskLine(TaskItem task, DateFormat dueFormat) {
    final tokens = <String>['[${task.priority}] ${task.title}'];
    if (task.category.isNotEmpty && task.category != 'general') {
      tokens.add('(${task.category})');
    }
    if (task.dueDateMs != null) {
      tokens.add(
        'due ${dueFormat.format(DateTime.fromMillisecondsSinceEpoch(task.dueDateMs!))}',
      );
    }
    return tokens.join(' ');
  }
}
