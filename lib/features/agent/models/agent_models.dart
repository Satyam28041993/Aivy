/// Models for the Aivy agent screen.
///
/// These mirror the shapes `functions/src/agent/` returns. Parsing is
/// deliberately forgiving — a field the backend adds later should not blank out
/// a conversation on an older build.
library;

/// One row on a confirm card, e.g. "Kab" / "Ravivar, 24 August, 11:00 AM".
class AgentCardLine {
  const AgentCardLine({required this.label, required this.value});

  final String label;
  final String value;

  factory AgentCardLine.fromMap(Map<String, dynamic> m) {
    return AgentCardLine(
      label: (m['label'] as String? ?? '').trim(),
      value: (m['value'] as String? ?? '').trim(),
    );
  }

  Map<String, dynamic> toMap() => {'label': label, 'value': value};
}

/// A proposed write, shown as a card. Nothing is saved until it is confirmed.
class AgentDraft {
  const AgentDraft({
    required this.id,
    required this.kind,
    required this.status,
    required this.title,
    required this.icon,
    required this.lines,
  });

  final String id;
  final String kind;

  /// pending | committed | cancelled | superseded
  final String status;
  final String title;
  final String icon;
  final List<AgentCardLine> lines;

  bool get isPending => status == 'pending';
  bool get isCommitted => status == 'committed';

  factory AgentDraft.fromMap(Map<String, dynamic> m) {
    final rawLines = m['lines'];
    return AgentDraft(
      id: (m['id'] as String? ?? '').trim(),
      kind: (m['kind'] as String? ?? '').trim(),
      status: (m['status'] as String? ?? 'pending').trim(),
      title: (m['title'] as String? ?? 'Record').trim(),
      icon: (m['icon'] as String? ?? '📝').trim(),
      lines: rawLines is List
          ? rawLines
              .whereType<Map>()
              .map((e) => AgentCardLine.fromMap(Map<String, dynamic>.from(e)))
              .toList(growable: false)
          : const [],
    );
  }

  AgentDraft copyWith({String? status}) {
    return AgentDraft(
      id: id,
      kind: kind,
      status: status ?? this.status,
      title: title,
      icon: icon,
      lines: lines,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'kind': kind,
        'status': status,
        'title': title,
        'icon': icon,
        'lines': lines.map((l) => l.toMap()).toList(growable: false),
      };
}

enum AgentRole { user, assistant }

/// One turn in the conversation.
class AgentMessage {
  const AgentMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAtMs,
    this.drafts = const [],
  });

  final String id;
  final AgentRole role;
  final String text;
  final int createdAtMs;
  final List<AgentDraft> drafts;

  bool get isUser => role == AgentRole.user;

  DateTime get createdAt => DateTime.fromMillisecondsSinceEpoch(createdAtMs);

  factory AgentMessage.fromMap(String id, Map<String, dynamic> m) {
    final rawDrafts = m['drafts'];
    final roleRaw = (m['role'] as String? ?? 'assistant').trim();
    return AgentMessage(
      id: (m['id'] as String? ?? id).trim(),
      role: roleRaw == 'user' ? AgentRole.user : AgentRole.assistant,
      text: (m['text'] as String? ?? '').trim(),
      createdAtMs: (m['createdAtMs'] as num?)?.toInt() ?? 0,
      drafts: rawDrafts is List
          ? rawDrafts
              .whereType<Map>()
              .map((e) => AgentDraft.fromMap(Map<String, dynamic>.from(e)))
              .where((d) => d.id.isNotEmpty)
              .toList(growable: false)
          : const [],
    );
  }
}

/// A conversation in the history list.
class AgentChatSummary {
  const AgentChatSummary({
    required this.id,
    required this.title,
    required this.updatedAtMs,
    required this.lastMessage,
  });

  final String id;
  final String title;
  final int updatedAtMs;
  final String lastMessage;

  DateTime get updatedAt => DateTime.fromMillisecondsSinceEpoch(updatedAtMs);

  factory AgentChatSummary.fromMap(String id, Map<String, dynamic> m) {
    return AgentChatSummary(
      id: (m['id'] as String? ?? id).trim(),
      title: (m['title'] as String? ?? 'Nayi baat').trim(),
      updatedAtMs: (m['updatedAtMs'] as num?)?.toInt() ?? 0,
      lastMessage: (m['lastMessage'] as String? ?? '').trim(),
    );
  }
}

/// What one call to `aivyAgent` produced.
class AgentTurnResponse {
  const AgentTurnResponse({
    required this.chatId,
    required this.reply,
    required this.drafts,
    required this.failed,
  });

  final String chatId;
  final String reply;
  final List<AgentDraft> drafts;
  final bool failed;

  factory AgentTurnResponse.fromMap(Map<String, dynamic> m) {
    final rawDrafts = m['drafts'];
    return AgentTurnResponse(
      chatId: (m['chatId'] as String? ?? '').trim(),
      reply: (m['reply'] as String? ?? '').trim(),
      drafts: rawDrafts is List
          ? rawDrafts
              .whereType<Map>()
              .map((e) => AgentDraft.fromMap(Map<String, dynamic>.from(e)))
              .toList(growable: false)
          : const [],
      failed: m['failed'] == true,
    );
  }
}

/// Result of confirming a card.
class AgentCommitResult {
  const AgentCommitResult({required this.ok, required this.message});

  final bool ok;
  final String message;

  factory AgentCommitResult.fromMap(Map<String, dynamic> m) {
    return AgentCommitResult(
      ok: m['ok'] == true,
      message: (m['message'] as String? ?? '').trim(),
    );
  }
}
