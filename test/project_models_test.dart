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

  group('ProjectSummary', () {
    final now = DateTime(2026, 9, 1, 10);
    ProjectRecord task({int dueMs = 0, String status = 'active'}) =>
        ProjectRecord.fromMap('t', <String, dynamic>{
          'name': 'Security label PPT and app',
          'clientName': 'Mandar sir',
          'kind': 'task',
          'status': status,
          'dueMs': dueMs,
        });

    ProjectItemRecord item(String status, {int dueMs = 0}) =>
        ProjectItemRecord.fromMap(status + dueMs.toString(), <String, dynamic>{
          'title': 'step',
          'status': status,
          'dueMs': dueMs,
        });

    test('counts a missed deadline as late', () {
      final s = ProjectSummary.from(
        task(dueMs: DateTime(2026, 8, 31).millisecondsSinceEpoch),
        [item('open'), item('done')],
        now: now,
      );
      expect(s.overdue, 1);
      expect(s.subtitle(now: now), 'Mandar sir · 1 late · 1 pending');
    });

    test('names what is owed and who is being waited on', () {
      final s = ProjectSummary.from(
        task(dueMs: DateTime(2026, 9, 2, 18).millisecondsSinceEpoch),
        [item('open'), item('waiting_on_them'), item('done')],
        now: now,
      );
      expect(s.overdue, 0);
      expect(s.subtitle(now: now), 'Mandar sir · due tomorrow · 1 pending · 1 waiting on them');
    });

    test('says all clear rather than nothing when the work is finished', () {
      // An empty line under a name reads as a bug, not as good news.
      final s = ProjectSummary.from(task(), [item('done'), item('done')], now: now);
      expect(s.subtitle(now: now), 'Mandar sir · all clear');
    });

    test('says so when nothing has been put in it yet', () {
      final s = ProjectSummary.from(task(), const [], now: now);
      expect(s.subtitle(now: now), 'Mandar sir · nothing in it yet');
    });

    test('takes the soonest live date, ignoring dates on finished steps', () {
      final soon = DateTime(2026, 9, 3).millisecondsSinceEpoch;
      final s = ProjectSummary.from(
        task(),
        [
          item('done', dueMs: DateTime(2026, 8, 20).millisecondsSinceEpoch),
          item('open', dueMs: soon),
        ],
        now: now,
      );
      expect(s.nextDueMs, soon);
      expect(s.overdue, 0);
    });
  });
}
