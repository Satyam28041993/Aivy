enum WhatsAppMessageDirection { inbound, outbound, unknown }

class WhatsAppMessage {
  const WhatsAppMessage({
    required this.id,
    required this.conversationId,
    required this.from,
    required this.type,
    required this.textBody,
    required this.media,
    required this.createdAtMs,
    required this.direction,
    required this.lastStatus,
    required this.aiQueued,
    required this.aiProcessed,
    required this.uiReadByAdmin,
  });

  final String id;
  final String conversationId;
  final String from;
  final String type;
  final String textBody;
  final Map<String, dynamic>? media;
  final int createdAtMs;
  final WhatsAppMessageDirection direction;
  final String lastStatus;
  final bool aiQueued;
  final bool aiProcessed;
  final bool uiReadByAdmin;

  bool get isInbound => direction == WhatsAppMessageDirection.inbound;
  bool get isOutbound => direction == WhatsAppMessageDirection.outbound;
  bool get aiPending => aiQueued && !aiProcessed;

  factory WhatsAppMessage.fromDoc(String id, Map<String, dynamic> data) {
    final status = data['status'];
    final ai = data['ai'];
    final rawDirection = (data['direction'] as String? ?? '').trim().toLowerCase();
    final direction = rawDirection == 'inbound'
        ? WhatsAppMessageDirection.inbound
        : rawDirection == 'outbound'
        ? WhatsAppMessageDirection.outbound
        : WhatsAppMessageDirection.unknown;
    return WhatsAppMessage(
      id: id,
      conversationId: (data['conversationId'] as String? ?? '').trim(),
      from: (data['from'] as String? ?? '').trim(),
      type: (data['type'] as String? ?? 'unknown').trim().toLowerCase(),
      textBody: (data['textBody'] as String? ?? '').trim(),
      media: data['media'] as Map<String, dynamic>?,
      createdAtMs: (data['createdAtMs'] as num?)?.toInt() ?? 0,
      direction: direction,
      lastStatus: status is Map<String, dynamic>
          ? (status['lastStatus'] as String? ?? '')
                .trim()
                .toLowerCase()
          : '',
      aiQueued: ai is Map<String, dynamic> ? (ai['queued'] == true) : false,
      aiProcessed: ai is Map<String, dynamic> ? (ai['processed'] == true) : false,
      uiReadByAdmin: data['uiReadByAdmin'] == true,
    );
  }
}
