import 'package:flutter_test/flutter_test.dart';

import 'package:aivy/features/projects/models/project_models.dart';

/// The detail sheet reads documents the server wrote, and the documents
/// written before tasks existed are missing three of the fields it reads.
/// Those must come back as a plain project rather than as nothing.
void main() {
  group('ProjectRecord', () {
    test('reads a doc written before tasks existed as a project', () {
      final p = ProjectRecord.fromMap('p1', <String, dynamic>{
        'name': 'Pune label project',
        'clientName': 'Sharma Packaging',
        'status': 'active',
      });
      expect(p.isTask, isFalse);
      expect(p.isPersonal, isFalse);
      expect(p.dueMs, 0);
      expect(p.isLive, isTrue);
      expect(p.forWhom, 'Sharma Packaging');
    });

    test('reads a task with its own deadline', () {
      final p = ProjectRecord.fromMap('t1', <String, dynamic>{
        'name': 'Security label PPT and app',
        'clientName': 'Mandar sir',
        'status': 'active',
        'kind': 'task',
        'area': 'work',
        'dueMs': 1756800000000,
      });
      expect(p.isTask, isTrue);
      expect(p.dueMs, 1756800000000);
    });

    test('on_hold still counts as live, closed does not', () {
      expect(
        ProjectRecord.fromMap('x', <String, dynamic>{'status': 'on_hold'}).isLive,
        isTrue,
      );
      expect(
        ProjectRecord.fromMap('x', <String, dynamic>{'status': 'won'}).isLive,
        isFalse,
      );
    });
  });

  group('ProjectItemRecord', () {
    test('keeps the same wording Aivy uses for a state', () {
      String label(String status) =>
          ProjectItemRecord.fromMap('i', <String, dynamic>{
            'title': 'Rate',
            'status': status,
          }).statusLabel;

      expect(label('waiting_on_them'), 'Waiting on them');
      expect(label('done'), 'Done');
      expect(label('dropped'), 'Dropped');
      expect(label('open'), 'Open');
      // A missing status is an open one, not a broken one.
      expect(label(''), 'Open');
    });
  });

  group('ProjectEventRecord', () {
    test('drops an entry with no text or no time', () {
      expect(
        ProjectEventRecord.fromMap('e', <String, dynamic>{'atMs': 1, 'text': ''}),
        isNull,
      );
      expect(
        ProjectEventRecord.fromMap('e', <String, dynamic>{'text': 'something'}),
        isNull,
      );
      expect(
        ProjectEventRecord.fromMap('e', <String, dynamic>{
          'atMs': 1756800000000,
          'kind': 'status',
          'text': 'PPT — done',
        }),
        isNotNull,
      );
    });
  });
}
