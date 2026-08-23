import 'package:flutter_test/flutter_test.dart';

import 'package:aivy/features/agent/models/agent_models.dart';

/// Parsing is the one place a backend change can silently blank out a
/// conversation, so these lock down the shapes the callables return — including
/// the loosely-typed maps that come back from `cloud_functions`.
void main() {
  group('AgentDraft', () {
    test('reads a full card', () {
      final draft = AgentDraft.fromMap(const {
        'id': 'd1',
        'kind': 'meeting',
        'status': 'pending',
        'title': 'Meeting',
        'icon': '📅',
        'lines': [
          {'label': 'Client', 'value': 'Rohan Traders'},
          {'label': 'Kab', 'value': 'Ravivar, 24 August, 11:00 AM'},
        ],
      });

      expect(draft.id, 'd1');
      expect(draft.isPending, isTrue);
      expect(draft.isCommitted, isFalse);
      expect(draft.lines, hasLength(2));
      expect(draft.lines.last.value, 'Ravivar, 24 August, 11:00 AM');
    });

    test('survives missing fields rather than throwing', () {
      final draft = AgentDraft.fromMap(const {'id': 'd2'});
      expect(draft.title, 'Record');
      expect(draft.icon, '📝');
      expect(draft.status, 'pending');
      expect(draft.lines, isEmpty);
    });

    test('ignores malformed line entries', () {
      final draft = AgentDraft.fromMap(const {
        'id': 'd3',
        'lines': ['not a map', 42],
      });
      expect(draft.lines, isEmpty);
    });

    test('copyWith only overrides the status', () {
      final draft = AgentDraft.fromMap(const {
        'id': 'd4',
        'title': 'Quotation',
        'status': 'pending',
      });
      final saved = draft.copyWith(status: 'committed');
      expect(saved.isCommitted, isTrue);
      expect(saved.title, 'Quotation');
      // A null override must leave the status alone.
      expect(draft.copyWith().status, 'pending');
    });
  });

  group('AgentMessage', () {
    test('reads a user turn', () {
      final msg = AgentMessage.fromMap('m1', const {
        'role': 'user',
        'text': 'kal 11 baje meeting hai',
        'createdAtMs': 1000,
      });
      expect(msg.isUser, isTrue);
      expect(msg.drafts, isEmpty);
      expect(msg.createdAt.millisecondsSinceEpoch, 1000);
    });

    test('reads an assistant turn carrying cards', () {
      final msg = AgentMessage.fromMap('m2', const {
        'role': 'assistant',
        'text': 'Ye taiyaar hai',
        'createdAtMs': 2000,
        'drafts': [
          {'id': 'd1', 'title': 'Meeting'},
          {'id': 'd2', 'title': 'Reminder'},
        ],
      });
      expect(msg.isUser, isFalse);
      expect(msg.drafts.map((d) => d.id), ['d1', 'd2']);
    });

    test('drops cards with no id — they cannot be confirmed', () {
      final msg = AgentMessage.fromMap('m3', const {
        'role': 'assistant',
        'drafts': [
          {'title': 'no id here'},
          {'id': 'ok'},
        ],
      });
      expect(msg.drafts.map((d) => d.id), ['ok']);
    });

    test('defaults an unknown role to assistant', () {
      final msg = AgentMessage.fromMap('m4', const {'role': 'system'});
      expect(msg.isUser, isFalse);
    });

    test('falls back to the document id', () {
      final msg = AgentMessage.fromMap('doc-id', const {});
      expect(msg.id, 'doc-id');
    });
  });

  group('AgentTurnResponse', () {
    test('reads a reply with cards', () {
      final res = AgentTurnResponse.fromMap(const {
        'chatId': 'c1',
        'reply': 'Meeting taiyaar hai',
        'drafts': [
          {'id': 'd1', 'title': 'Meeting'},
        ],
        'failed': false,
      });
      expect(res.chatId, 'c1');
      expect(res.drafts, hasLength(1));
      expect(res.failed, isFalse);
    });

    test('surfaces a failed turn', () {
      final res = AgentTurnResponse.fromMap(const {
        'chatId': 'c1',
        'reply': 'gadbad',
        'failed': true,
      });
      expect(res.failed, isTrue);
      expect(res.drafts, isEmpty);
    });
  });

  group('AgentChatSummary', () {
    test('reads a history row', () {
      final chat = AgentChatSummary.fromMap('c1', const {
        'title': 'kal 11 baje meeting',
        'updatedAtMs': 5000,
        'lastMessage': 'Save ho gaya',
      });
      expect(chat.title, 'kal 11 baje meeting');
      expect(chat.updatedAt.millisecondsSinceEpoch, 5000);
    });

    test('titles an empty chat', () {
      final chat = AgentChatSummary.fromMap('c2', const {});
      expect(chat.title, 'Nayi baat');
    });
  });

  group('AgentCommitResult', () {
    test('reads success and failure', () {
      expect(
        AgentCommitResult.fromMap(const {'ok': true, 'message': 'Save ho gaya'}).ok,
        isTrue,
      );
      expect(AgentCommitResult.fromMap(const {'ok': false}).ok, isFalse);
    });
  });
}
