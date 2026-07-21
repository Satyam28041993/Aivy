import 'package:flutter_test/flutter_test.dart';
import 'package:aivy/features/chat/models/aivy_ai_response.dart';
import 'package:aivy/features/reminders/utils/reminder_time_parser.dart';

void main() {
  test('AivyAiResponse parses expected payload', () {
    final payload = {
      'contextType': 'task',
      'summary': 'Send pricing update to client',
      'keyPoints': ['Client waiting for final quote'],
      'actionItems': ['Draft pricing note', 'Send by 5 PM'],
      'followUpSuggestions': [
        {'when': 'Tomorrow morning', 'reason': 'Confirm receipt'},
      ],
      'reminderSuggestions': [
        {
          'title': 'Send pricing update',
          'timeHint': 'Today 4:30 PM',
          'priority': 'high',
          'scheduledAtIso': '2026-04-08T16:30:00',
        },
      ],
      'assistantReply':
          'Noted. I suggest sending it before 5 PM and following up tomorrow.',
    };

    final response = AivyAiResponse.fromJson(payload);
    expect(response.contextType, 'task');
    expect(response.keyPoints.first, 'Client waiting for final quote');
    expect(response.actionItems.length, 2);
    expect(response.reminderSuggestions.first.priority, 'high');
    expect(
      response.reminderSuggestions.first.scheduledAtIso,
      '2026-04-08T16:30:00',
    );
  });

  test('ReminderTimeParser parses natural language fallback', () {
    final suggestion = ReminderSuggestion(
      title: 'Buy medicine',
      timeHint: 'tomorrow 7 PM',
      priority: 'medium',
    );
    final reference = DateTime(2026, 4, 8, 10, 0);
    final parsed = ReminderTimeParser.resolveScheduledTime(
      suggestion,
      reference: reference,
    );
    expect(parsed, isNotNull);
    final t = parsed!;

    expect(t.year, 2026);
    expect(t.month, 4);
    expect(t.day, 9);
    expect(t.hour, 19);
    expect(t.minute, 0);
  });
}
