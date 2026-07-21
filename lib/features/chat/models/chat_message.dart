import 'package:cloud_firestore/cloud_firestore.dart';

enum ChatRole { user, assistant }

/// Shown as a compact chip on assistant bubbles when the cloud intent matches.
enum ChatIntentTag { jobDispatch, paymentDue }

extension ChatRoleX on ChatRole {
  String get value => switch (this) {
    ChatRole.user => 'user',
    ChatRole.assistant => 'assistant',
  };

  static ChatRole fromValue(String? role) {
    return role == 'user' ? ChatRole.user : ChatRole.assistant;
  }
}

enum ChatMessageType { text, voice, system }

extension ChatMessageTypeX on ChatMessageType {
  String get value => switch (this) {
    ChatMessageType.text => 'text',
    ChatMessageType.voice => 'voice',
    ChatMessageType.system => 'system',
  };

  static ChatMessageType fromValue(String? type) {
    switch (type) {
      case 'voice':
        return ChatMessageType.voice;
      case 'system':
        return ChatMessageType.system;
      case 'text':
      default:
        return ChatMessageType.text;
    }
  }
}

enum TranscriptStatus { processing, done, failed }

extension TranscriptStatusX on TranscriptStatus {
  String get value => switch (this) {
    TranscriptStatus.processing => 'processing',
    TranscriptStatus.done => 'done',
    TranscriptStatus.failed => 'failed',
  };

  static TranscriptStatus? fromValue(String? status) {
    switch (status) {
      case 'processing':
        return TranscriptStatus.processing;
      case 'done':
        return TranscriptStatus.done;
      case 'failed':
        return TranscriptStatus.failed;
      default:
        return null;
    }
  }
}

extension ChatIntentTagX on ChatIntentTag {
  String get wireValue => switch (this) {
    ChatIntentTag.jobDispatch => 'job_dispatch',
    ChatIntentTag.paymentDue => 'payment_due',
  };

  static ChatIntentTag? fromWire(String? raw) {
    switch (raw?.trim()) {
      case 'job_dispatch':
      case 'order_dispatched':
        return ChatIntentTag.jobDispatch;
      case 'payment_due':
        return ChatIntentTag.paymentDue;
      default:
        return null;
    }
  }
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAtMs,
    this.entryId,
    this.type = ChatMessageType.text,
    this.audioUrl,
    this.durationMs,
    this.transcript,
    this.transcriptStatus,
    this.intentTag,
    this.aivyData,
    this.isError = false,
  });

  final String id;
  final ChatRole role;
  final String text;
  final int createdAtMs;
  final String? entryId;
  final ChatMessageType type;
  final String? audioUrl;
  final int? durationMs;
  final String? transcript;
  final TranscriptStatus? transcriptStatus;
  final ChatIntentTag? intentTag;
  /// Optional structured payload from the cloud (e.g. dispatch order picker rows).
  final Map<String, dynamic>? aivyData;
  final bool isError;

  String get senderLabel => switch (role) {
    ChatRole.user => 'You',
    ChatRole.assistant => 'Aivy',
  };

  bool get isVoice => type == ChatMessageType.voice;
  bool get isSystem => type == ChatMessageType.system;

  factory ChatMessage.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final rawAivy = data['aivyData'];
    return ChatMessage(
      id: doc.id,
      role: ChatRoleX.fromValue(data['role'] as String?),
      text: data['text'] as String? ?? '',
      createdAtMs: (data['createdAtMs'] as num?)?.toInt() ?? 0,
      entryId: data['entryId'] as String?,
      type: ChatMessageTypeX.fromValue(data['type'] as String?),
      audioUrl: data['audioUrl'] as String?,
      durationMs: (data['durationMs'] as num?)?.toInt(),
      transcript: data['transcript'] as String?,
      transcriptStatus: TranscriptStatusX.fromValue(
        data['transcriptStatus'] as String?,
      ),
      intentTag: ChatIntentTagX.fromWire(data['intent'] as String?),
      aivyData: rawAivy is Map
          ? Map<String, dynamic>.from(rawAivy)
          : null,
      isError: data['isError'] == true,
    );
  }
}
