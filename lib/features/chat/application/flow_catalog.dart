/// Top-level flow categories (Step 3–4).
const List<FlowCategoryOption> kFlowCategories = [
  FlowCategoryOption(id: 'reminder', label: 'Reminder'),
  FlowCategoryOption(id: 'payment', label: 'Payment'),
  FlowCategoryOption(id: 'order', label: 'Order'),
  FlowCategoryOption(id: 'quotation', label: 'Quotation'),
  FlowCategoryOption(id: 'followup', label: 'Follow-up'),
  FlowCategoryOption(id: 'personal', label: 'Personal'),
  FlowCategoryOption(id: 'reports', label: 'Reports'),
];

class FlowCategoryOption {
  const FlowCategoryOption({required this.id, required this.label});

  final String id;
  final String label;
}

class FlowSubcategoryOption {
  const FlowSubcategoryOption({required this.id, required this.label});

  final String id;
  final String label;
}

List<FlowSubcategoryOption> subcategoriesFor(String categoryId) {
  switch (categoryId) {
    case 'payment':
      return const [
        FlowSubcategoryOption(id: 'received', label: 'Payment received'),
        FlowSubcategoryOption(id: 'due', label: 'Payment due'),
        FlowSubcategoryOption(
          id: 'followup',
          label: 'Follow-up',
        ),
      ];
    case 'reminder':
      return const [
        FlowSubcategoryOption(id: 'call', label: 'Call'),
        FlowSubcategoryOption(id: 'meeting', label: 'Meeting'),
        FlowSubcategoryOption(id: 'task', label: 'Task'),
        FlowSubcategoryOption(
          id: 'followup',
          label: 'Follow-up',
        ),
      ];
    case 'order':
      return const [
        FlowSubcategoryOption(id: 'new', label: 'New order'),
        FlowSubcategoryOption(id: 'update', label: 'Update / note'),
      ];
    case 'quotation':
      return const [
        FlowSubcategoryOption(id: 'new', label: 'New quotation'),
        FlowSubcategoryOption(
          id: 'followup',
          label: 'Follow-up',
        ),
      ];
    case 'followup':
      return const [
        FlowSubcategoryOption(
          id: 'client',
          label: 'Client follow-up',
        ),
      ];
    case 'personal':
      return const [
        FlowSubcategoryOption(id: 'task', label: 'Personal reminder'),
        FlowSubcategoryOption(id: 'birthday', label: 'Birthday tracker'),
      ];
    case 'reports':
      return const [
        FlowSubcategoryOption(
          id: 'status',
          label: 'Business status',
        ),
        FlowSubcategoryOption(
          id: 'analytics',
          label: 'Custom question',
        ),
      ];
    default:
      return const [];
  }
}

/// Ordered field keys for [category:subType].
List<String> fieldKeysFor(String category, String sub) {
  final k = '$category:$sub';
  const map = <String, List<String>>{
    // Payment received uses due-selection + settlement steps in [ControlledChatFlow],
    // not the generic field collector (resume edge-case only: amount → date).
    'payment:received': ['amount', 'date'],
    'payment:due': ['clientName', 'amount', 'date'],
    'payment:followup': ['clientName', 'amount', 'date'],
    'reminder:call': ['clientName', 'date', 'time', 'note'],
    'reminder:meeting': ['clientName', 'date', 'time', 'note'],
    'reminder:task': ['taskTitle', 'date', 'priority', 'note'],
    'reminder:followup': ['clientName', 'date', 'time', 'note'],
    'order:new': ['clientName', 'amount', 'note'],
    'order:update': ['clientName', 'note'],
    'quotation:new': ['clientName', 'amount', 'date'],
    'quotation:followup': ['clientName', 'date', 'note'],
    'followup:client': ['clientName', 'date', 'note'],
    'personal:task': ['name', 'date', 'note'],
    'personal:birthday': ['name', 'birthDate', 'note'],
    'reports:status': ['query'],
    'reports:analytics': ['query'],
  };
  return map[k] ?? const ['name', 'note'];
}

String fieldPrompt(
  String key, {
  String? category,
  String? sub,
}) {
  if (category == 'reminder' && sub == 'task') {
    switch (key) {
      case 'taskTitle':
        return '📝 Task kya hai? (e.g. client ka artwork approve karwana hai)';
      case 'date':
        return '📅 Kab tak karna hai? (deadline) — kal 5pm, aaj, 2 din baad 3 baje';
      case 'priority':
        return '⚡ Priority kya hai? (High / Medium / Low)';
      case 'note':
        return '🧾 Extra details (optional)';
      default:
        break;
    }
  }
  if (category == 'payment' && sub == 'received') {
    switch (key) {
      case 'amount':
        return 'Kitna payment receive hua? (₹)';
      case 'date':
        return '📅 Payment receive date? (aaj / kal / 5 May — default aaj)';
      default:
        break;
    }
  }
  if (category == 'personal' && sub == 'task') {
    switch (key) {
      case 'name':
        return 'Task kya hai? (e.g. medicine lena, drawing book buy karna)';
      case 'date':
        return 'Kab yaad dilau? (e.g. kal 7pm, 20 May 10:30am)';
      case 'note':
        return 'Extra note? (optional)';
      default:
        break;
    }
  }
  if (category == 'personal' && sub == 'birthday') {
    switch (key) {
      case 'name':
        return 'Kiska birthday hai?';
      case 'birthDate':
        return 'Birthday date? (e.g. 20-05, 20/05, 20 May)';
      case 'note':
        return 'Relation / note? (optional)';
      default:
        break;
    }
  }
  switch (key) {
    case 'clientName':
      return 'Client name? ( naam )';
    case 'name':
      return 'Name?';
    case 'amount':
      return 'Amount? (₹)';
    case 'date':
      return 'Date? (e.g. kal, aaj, 10 din baad — saath mein time bhi: kal 5pm)';
    case 'note':
      return 'Note? (optional details)';
    case 'query':
      return 'What do you want to know? (Hinglish ok)';
    case 'time':
      return 'Kitne baje yaad dilau? (e.g. 10 baje, 3:30pm — “skip” = 11 baje)';
    case 'birthDate':
      return 'Birthday date? (e.g. 20-05, 20/05, 20 May)';
    default:
      return 'Value?';
  }
}

/// Single lock id for the whole flow: e.g. [reminder_call], [payment_due], [order_new].
String flowCategoryIdFor(String category, String sub) => '${category}_$sub';

/// [StructuredAction.subType] for payment is `payment_due` / `payment_received`; keys must match [flowCategoryIdFor] ids.
String flowCategoryIdFromActionTypes(String type, String subType) {
  if (type == 'followup' &&
      (subType == 'payment' || subType == 'payment_followup')) {
    return 'followup_payment';
  }
  if (type == 'payment') {
    switch (subType) {
      case 'payment_received':
      case 'payment_due':
      case 'payment_followup':
        return subType;
      default:
        break;
    }
  }
  return flowCategoryIdFor(type, subType);
}

/// Maps flow to [StructuredAction.type] / [subType] strings in Firestore.
String structuredTypeFor(String category) => category;

String structuredSubTypeFor(String category, String sub) {
  if (category == 'payment' && sub == 'received') {
    return 'payment_received';
  }
  if (category == 'payment' && sub == 'due') {
    return 'payment_due';
  }
  if (category == 'payment' && sub == 'followup') {
    return 'payment_followup';
  }
  return sub;
}
