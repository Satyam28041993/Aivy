class WhatsAppConversation {
  const WhatsAppConversation({
    required this.id,
    required this.phone,
    required this.waProfileName,
    required this.customerName,
    required this.lastMessage,
    required this.lastMessageType,
    required this.lastMessageAtMs,
    required this.unreadCountAdmin,
    required this.leadStatus,
    required this.lastDeliveryStatus,
  });

  final String id;
  final String phone;
  /// WhatsApp display name from webhook / Cloud API (may be empty).
  final String waProfileName;
  final String customerName;
  final String lastMessage;
  final String lastMessageType;
  final int lastMessageAtMs;
  final int unreadCountAdmin;
  final String leadStatus;
  final String lastDeliveryStatus;

  factory WhatsAppConversation.fromDoc(
    String id,
    Map<String, dynamic> data,
  ) {
    var phone = (data['from'] as String? ?? '').trim();
    if (phone.isEmpty) {
      // Outbound-only threads use doc id = E.164 phone before first inbound sync.
      phone = id.trim();
    }
    final profileName = (data['profileName'] as String? ?? '').trim();
    final lastMessageText = (data['lastMessageTextPreview'] as String? ?? '').trim();
    return WhatsAppConversation(
      id: id,
      phone: phone,
      waProfileName: profileName,
      customerName: profileName.isEmpty ? phone : profileName,
      lastMessage: lastMessageText,
      lastMessageType: (data['lastMessageType'] as String? ?? 'unknown').trim(),
      lastMessageAtMs: (data['lastMessageAtMs'] as num?)?.toInt() ?? 0,
      unreadCountAdmin: (data['unreadCountAdmin'] as num?)?.toInt() ?? 0,
      leadStatus: (data['leadStatus'] as String? ?? 'new').trim().toLowerCase(),
      lastDeliveryStatus: (data['lastDeliveryStatus'] as String? ?? '')
          .trim()
          .toLowerCase(),
    );
  }

  /// When WhatsApp never sent a profile name, show CRM contact name instead of raw phone.
  WhatsAppConversation withCrmNameIfMissing(String? crmName) {
    if (waProfileName.isNotEmpty) {
      return this;
    }
    final n = (crmName ?? '').trim();
    if (n.isEmpty) {
      return this;
    }
    return WhatsAppConversation(
      id: id,
      phone: phone,
      waProfileName: waProfileName,
      customerName: n,
      lastMessage: lastMessage,
      lastMessageType: lastMessageType,
      lastMessageAtMs: lastMessageAtMs,
      unreadCountAdmin: unreadCountAdmin,
      leadStatus: leadStatus,
      lastDeliveryStatus: lastDeliveryStatus,
    );
  }
}
