import 'package:aivy/features/projects/utils/project_confirm.dart';
import 'package:aivy/features/projects/utils/project_intent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const dump =
      'Sharma ko 3 label sample dikhaye, glossy wala pasand aaya, rate Monday tak dena hai, unka QC head 5 tarikh ko aayega';

  test('multi-item field note is a project dump, not a simple reminder', () {
    expect(looksLikeProjectDump(dump), isTrue);
    expect(looksLikeProjectTurn(dump), isTrue);
  });

  test('simple call reminder is not a project dump', () {
    expect(looksLikeProjectDump('rajesh ko aaj 3 baje call karna hai'), isFalse);
    expect(looksLikeProjectTurn('Pune project ka kya haal hai'), isTrue);
  });

  test('project confirm map formats waiting_on_them items', () {
    final map = projectDraftToConfirmMap({
      'projectName': 'Pune',
      'client': 'Sharma',
      'items': [
        {
          'title': 'Rate dena',
          'kind': 'rate',
          'status': 'waiting_on_them',
          'dueLabel': 'Mon 11:00 AM',
          'waitingOn': 'Sharma',
        },
      ],
    });
    expect(isProjectConfirmMap(map), isTrue);
    final summary = formatProjectConfirmSummary(map);
    expect(summary, contains('Pune'));
    expect(summary.toLowerCase(), contains('waiting on them'));
  });
}
