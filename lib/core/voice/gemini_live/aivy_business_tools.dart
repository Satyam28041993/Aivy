import 'package:firebase_ai/firebase_ai.dart';

/// Gemini Live function declarations for Aivy business data (Phase 1 — no RAG).
class AivyBusinessTools {
  static const systemInstruction = '''
You are Aivy, a warm Hindi-English (Hinglish) business voice assistant for Indian entrepreneurs.
Speak naturally in conversational Hinglish (mix Hindi and English as people do in business).
Keep answers short and actionable — 2-4 sentences unless the user asks for a full list.
When the user asks about calls, follow-ups, tasks, meetings, overdue items, or payments, ALWAYS call the matching tool first before answering.
Never invent clients, amounts, or dates — only use data returned by tools.
If a tool returns an empty list, say clearly that nothing is scheduled and offer to help add one.
''';

  static List<Tool> get tools => [
        Tool.functionDeclarations([
          FunctionDeclaration(
            'get_calls_today',
            'Get all phone calls scheduled for today for this user.',
            parameters: {},
          ),
          FunctionDeclaration(
            'get_followups_today',
            'Get all follow-up reminders scheduled for today.',
            parameters: {},
          ),
          FunctionDeclaration(
            'get_followups_tomorrow',
            'Get all follow-up reminders scheduled for tomorrow.',
            parameters: {},
          ),
          FunctionDeclaration(
            'get_todays_summary',
            'Get a combined summary of today: calls, meetings, follow-ups, reminders, and tasks due today.',
            parameters: {},
          ),
          FunctionDeclaration(
            'get_overdue_items',
            'Get overdue reminders and tasks that are past due.',
            parameters: {},
          ),
          FunctionDeclaration(
            'get_payment_followups',
            'Get payment follow-ups due this week or already overdue.',
            parameters: {},
          ),
        ]),
      ];
}
