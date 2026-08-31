import '../../structured_actions/models/structured_action.dart';
import '../models/project_models.dart';

const kProjectFlowCategoryId = 'project_items';

Map<String, dynamic> projectDraftToConfirmMap(Map<String, dynamic> draft) {
  final itemsRaw = draft['items'];
  final items = <Map<String, dynamic>>[];
  if (itemsRaw is List) {
    for (final e in itemsRaw) {
      if (e is Map) {
        items.add(Map<String, dynamic>.from(e));
      }
    }
  }
  final name = (draft['projectName'] as String? ?? draft['name'] as String? ?? '')
      .trim();
  return {
    'flowCategoryId': kProjectFlowCategoryId,
    'type': 'project',
    'subType': 'items',
    'name': name,
    'projectName': name,
    'client': (draft['client'] as String? ?? '').trim(),
    'projectId': draft['projectId'],
    'sourceText': (draft['sourceText'] as String? ?? '').trim(),
    'items': items,
    'status': 'pending',
  };
}

StructuredAction projectDraftAction(Map<String, dynamic> map) {
  return StructuredAction(
    type: 'project',
    subType: 'items',
    name: (map['projectName'] as String? ?? map['name'] as String? ?? '').trim(),
    note: (map['client'] as String? ?? '').trim(),
    status: 'pending',
    createdAt: DateTime.now(),
  );
}

String formatProjectConfirmSummary(Map<String, dynamic> map) {
  final name =
      (map['projectName'] as String? ?? map['name'] as String? ?? '').trim();
  final client = (map['client'] as String? ?? '').trim();
  final items = <Map<String, dynamic>>[];
  final raw = map['items'];
  if (raw is List) {
    for (final e in raw) {
      if (e is Map) {
        items.add(Map<String, dynamic>.from(e));
      }
    }
  }
  final lines = <String>[
    'Project: ${name.isEmpty ? "—" : name}${client.isNotEmpty ? " · $client" : ""}',
    '',
  ];
  for (var i = 0; i < items.length; i++) {
    final it = items[i];
    final title = (it['title'] as String? ?? '').trim();
    final kind = (it['kind'] as String? ?? 'general').trim();
    final status = (it['status'] as String? ?? 'pending').trim();
    final statusLabel =
        status == 'waiting_on_them' ? 'waiting on them' : status;
    final due = (it['dueLabel'] as String? ?? '').trim();
    final who = (it['waitingOn'] as String? ?? '').trim();
    final extra = [
      if (due.isNotEmpty) due,
      if (who.isNotEmpty) who,
    ].join(' · ');
    lines.add(
      '${i + 1}. [$kind] $title — $statusLabel${extra.isNotEmpty ? " · $extra" : ""}',
    );
  }
  lines.add('');
  lines.add('Confirm / Edit / Cancel — save se pehle theek kar lo.');
  return lines.join('\n');
}

List<Map<String, dynamic>> projectItemsFromMap(Map<String, dynamic> map) {
  final raw = map['items'];
  if (raw is! List) {
    return const [];
  }
  return [
    for (final e in raw)
      if (e is Map) Map<String, dynamic>.from(e),
  ];
}

bool isProjectConfirmMap(Map<String, dynamic> map) {
  final fcid = (map['flowCategoryId'] as String? ?? '').trim();
  return fcid == kProjectFlowCategoryId ||
      (map['type'] as String? ?? '') == 'project';
}

String projectItemStatusLabel(String status) {
  switch (status) {
    case 'waiting_on_them':
      return 'Waiting on them';
    case 'done':
      return 'Done';
    case 'cancelled':
      return 'Cancelled';
    default:
      return 'Pending';
  }
}

List<ProjectItemRecord> todayProjectRows({
  required List<ProjectItemRecord> openItems,
  required DateTime startOfToday,
  required DateTime startOfTomorrow,
}) {
  final start = startOfToday.millisecondsSinceEpoch;
  final end = startOfTomorrow.millisecondsSinceEpoch;
  return openItems.where((i) {
    final due = i.dueAtMs;
    if (due != null && due >= start && due < end) {
      return true;
    }
    if (i.status == 'waiting_on_them' && due != null && due < end) {
      return true;
    }
    return false;
  }).toList();
}
