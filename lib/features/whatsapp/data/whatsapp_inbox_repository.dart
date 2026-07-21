import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/auth/firebase_admin_claims.dart';
import '../../contacts/data/contact_service.dart';
import '../models/whatsapp_conversation.dart';
import '../models/whatsapp_message.dart';

class WhatsAppInboxRepository {
  WhatsAppInboxRepository({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
    ContactService? contactService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _functions =
           functions ?? FirebaseFunctions.instanceFor(region: 'us-central1'),
       _contacts = contactService ?? ContactService();

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;
  final ContactService _contacts;

  CollectionReference<Map<String, dynamic>> get _conversations =>
      _firestore.collection('whatsapp_conversations');

  Stream<List<WhatsAppConversation>> watchConversations() {
    return _conversations
        .orderBy('lastMessageAtMs', descending: true)
        .limit(300)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => WhatsAppConversation.fromDoc(d.id, d.data()))
              .toList(growable: false),
        );
  }

  /// Same as [watchConversations], but fills missing display names from CRM `contacts`.
  Stream<List<WhatsAppConversation>> watchConversationsForOwner(String ownerUid) {
    final uid = ownerUid.trim();
    if (uid.isEmpty) {
      return watchConversations();
    }
    return _conversations
        .orderBy('lastMessageAtMs', descending: true)
        .limit(300)
        .snapshots()
        .asyncMap((snap) async {
          final list = snap.docs
              .map((d) => WhatsAppConversation.fromDoc(d.id, d.data()))
              .toList(growable: false);
          final names = await _contacts.phoneToNameMap(uid);
          return list
              .map((c) => c.withCrmNameIfMissing(names[c.phone]))
              .toList(growable: false);
        });
  }

  Stream<int> watchUnreadBadgeCount() {
    return watchConversations().map((rows) {
      var total = 0;
      for (final c in rows) {
        total += c.unreadCountAdmin;
      }
      return total;
    });
  }

  Stream<List<WhatsAppMessage>> watchMessages(String conversationId) {
    return _conversations
        .doc(conversationId)
        .collection('whatsapp_messages')
        .orderBy('createdAtMs')
        .limit(500)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => WhatsAppMessage.fromDoc(d.id, d.data()))
              .toList(growable: false),
        );
  }

  Future<void> markConversationRead(String conversationId) async {
    final convoRef = _conversations.doc(conversationId);
    final messages = await convoRef
        .collection('whatsapp_messages')
        .where('direction', isEqualTo: 'inbound')
        .orderBy('createdAtMs', descending: true)
        .limit(250)
        .get();
    final batch = _firestore.batch();
    var changed = false;
    for (final d in messages.docs) {
      final data = d.data();
      if (data['uiReadByAdmin'] == true) {
        continue;
      }
      changed = true;
      batch.set(d.reference, {
        'uiReadByAdmin': true,
        'uiReadByAdminAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
      }, SetOptions(merge: true));
    }
    batch.set(convoRef, {
      'unreadCountAdmin': 0,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
    }, SetOptions(merge: true));
    await batch.commit();
    if (!changed) {
      return;
    }
  }

  Future<void> setLeadStatus({
    required String conversationId,
    required String leadStatus,
  }) async {
    await _conversations.doc(conversationId).set({
      'leadStatus': leadStatus.trim().toLowerCase(),
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
    }, SetOptions(merge: true));
  }

  Future<void> sendAdminReply({
    required String conversationId,
    required String phone,
    required String message,
  }) async {
    final text = message.trim();
    if (text.isEmpty) {
      return;
    }
    final isAdmin = await currentUserIsFirebaseAdmin();
    if (!isAdmin) {
      throw Exception('Only administrators can send WhatsApp replies.');
    }
    final callable = _functions.httpsCallable('testWhatsapp');
    final response = await (() async {
      try {
        return await callable.call(<String, String>{
          'phone': phone.trim(),
          'message': text,
        });
      } on FirebaseFunctionsException catch (e) {
        final raw = (e.message ?? e.code).toLowerCase();
        if (e.code == 'permission-denied' &&
            raw.contains('admin access required')) {
          throw Exception('Only administrators can send WhatsApp replies.');
        }
        if (raw.contains('#131005') || raw.contains('access denied')) {
          throw Exception(
            'Meta denied this send (131005). If app is in test mode, add this recipient as a WhatsApp test number in Meta.',
          );
        }
        throw Exception(e.message ?? e.code);
      }
    })();
    final data = response.data is Map
        ? Map<String, dynamic>.from(response.data as Map)
        : const <String, dynamic>{};
    final messageId = '${data['messageId'] ?? ''}'.trim();
    final id = messageId.isEmpty
        ? _conversations.doc(conversationId).collection('whatsapp_messages').doc().id
        : messageId;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await _conversations
        .doc(conversationId)
        .collection('whatsapp_messages')
        .doc(id)
        .set({
          'id': id,
          'conversationId': conversationId,
          'from': 'admin',
          'direction': 'outbound',
          'type': 'text',
          'textBody': text,
          'uiReadByAdmin': true,
          'status': {
            'lastStatus': 'sent',
            'sentAtSec': (nowMs / 1000).floor(),
            'lastStatusAtSec': (nowMs / 1000).floor(),
          },
          'createdAt': FieldValue.serverTimestamp(),
          'createdAtMs': nowMs,
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedAtMs': nowMs,
        }, SetOptions(merge: true));

    await _firestore.collection('whatsapp_message_index').doc(id).set({
      'messageId': id,
      'conversationId': conversationId,
      'from': phone.trim(),
      'profileName': 'Admin',
      'lastStatus': 'sent',
      'lastStatusAtSec': (nowMs / 1000).floor(),
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': nowMs,
    }, SetOptions(merge: true));

    await _conversations.doc(conversationId).set({
      'lastMessageTextPreview': text,
      'lastMessageType': 'text',
      'lastDirection': 'outbound',
      'lastDeliveryStatus': 'sent',
      'lastDeliveryStatusAtSec': (nowMs / 1000).floor(),
      'lastMessageAt': FieldValue.serverTimestamp(),
      'lastMessageAtMs': nowMs,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': nowMs,
    }, SetOptions(merge: true));
  }

  Future<void> sendOutboundToPhone({
    required String phone,
    required String message,
    String contactDisplayName = '',
  }) async {
    final p = phone.trim();
    final text = message.trim();
    if (p.isEmpty) {
      throw ArgumentError('phone empty');
    }
    if (text.isEmpty) {
      throw ArgumentError('message empty');
    }
    final callable = _functions.httpsCallable('userSendWhatsapp');
    final payload = <String, String>{
      'phone': p,
      'message': text,
    };
    final cn = contactDisplayName.trim();
    if (cn.isNotEmpty) {
      payload['contactName'] = cn;
    }
    try {
      await callable.call(payload);
    } on FirebaseFunctionsException catch (e) {
      final raw = (e.message ?? e.code).toLowerCase();
      if (raw.contains('#131005') || raw.contains('access denied')) {
        throw Exception(
          'Meta denied this send (131005). If app is in test mode, add this recipient as a WhatsApp test number in Meta.',
        );
      }
      throw Exception(e.message ?? e.code);
    }
  }
}
