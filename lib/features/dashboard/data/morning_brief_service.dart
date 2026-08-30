import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import '../../../core/firebase/firebase_session.dart';
import '../models/morning_brief.dart';

/// Fetches the morning brief, and knows when not to.
///
/// The server builds it once a day and returns the same one afterwards, so
/// calling on every open is cheap. What is not cheap is the first call of the
/// day — it reads three slices of the mailbox and asks the model to write —
/// so the screen shows what it has and fills this in when it arrives.
class MorningBriefService {
  MorningBriefService({FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  final FirebaseFunctions _functions;

  Future<MorningBrief?> fetch({bool force = false}) async {
    try {
      // Gmail needs the device's own Google token; there is none on web, and
      // the brief then comes back with its mail sections honestly empty.
      final token = await FirebaseSession.googleAccessTokenOrNull();
      final res = await _functions
          .httpsCallable(
            'aivyMorningBrief',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 120)),
          )
          .call<Map<String, dynamic>>({
        // The whole app assumes this zone — the reminder engine and the date
        // resolver both do — so sending anything else would only disagree
        // with them.
        'timezone': 'Asia/Kolkata',
        // The server cannot tell a browser from a phone that simply has not
        // granted Google, and the two need different things said about them.
        'platform': kIsWeb ? 'web' : 'android',
        if (token != null) 'googleAccessToken': token,
        if (force) 'force': true,
      });
      final raw = res.data['brief'];
      if (raw is Map) {
        return MorningBrief.fromMap(Map<String, dynamic>.from(raw));
      }
      return null;
    } catch (e) {
      debugPrint('MorningBriefService: $e');
      return null;
    }
  }
}
