class ProjectRecord {
  const ProjectRecord({
    required this.id,
    required this.name,
    required this.client,
    required this.status,
    this.notes = '',
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
  });

  final String id;
  final String name;
  final String client;
  final String status;
  final String notes;
  final int createdAtMs;
  final int updatedAtMs;

  factory ProjectRecord.fromMap(String id, Map<String, dynamic> d) {
    return ProjectRecord(
      id: id,
      name: (d['name'] as String? ?? '').trim(),
      client: (d['client'] as String? ?? '').trim(),
      status: (d['status'] as String? ?? 'active').trim().isEmpty
          ? 'active'
          : (d['status'] as String).trim(),
      notes: (d['notes'] as String? ?? '').trim(),
      createdAtMs: (d['createdAtMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (d['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class ProjectItemRecord {
  const ProjectItemRecord({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.title,
    this.description = '',
    this.kind = 'general',
    this.status = 'pending',
    this.dueAtMs,
    this.waitingOn = '',
    this.notes = '',
    this.reminderId,
  });

  final String id;
  final String projectId;
  final String projectName;
  final String title;
  final String description;
  final String kind;
  final String status;
  final int? dueAtMs;
  final String waitingOn;
  final String notes;
  final String? reminderId;

  bool get isOpen => status == 'pending' || status == 'waiting_on_them';

  factory ProjectItemRecord.fromMap(String id, Map<String, dynamic> d) {
    return ProjectItemRecord(
      id: id,
      projectId: (d['projectId'] as String? ?? '').trim(),
      projectName: (d['projectName'] as String? ?? '').trim(),
      title: (d['title'] as String? ?? '').trim(),
      description: (d['description'] as String? ?? '').trim(),
      kind: (d['kind'] as String? ?? 'general').trim().isEmpty
          ? 'general'
          : (d['kind'] as String).trim(),
      status: (d['status'] as String? ?? 'pending').trim().isEmpty
          ? 'pending'
          : (d['status'] as String).trim(),
      dueAtMs: (d['dueAtMs'] as num?)?.toInt(),
      waitingOn: (d['waitingOn'] as String? ?? '').trim(),
      notes: (d['notes'] as String? ?? '').trim(),
      reminderId: (d['reminderId'] as String?)?.trim().isEmpty ?? true
          ? null
          : (d['reminderId'] as String).trim(),
    );
  }
}
