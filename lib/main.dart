import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import 'app/aivy_app.dart';
import 'core/firebase/aivy_app_check_setup.dart';
import 'core/notifications/notification_service.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  // Web is handled inside: it activates only when a reCAPTCHA site key was
  // supplied, because the plugin's presence alone makes the JS SDK send a
  // dummy App Check token that AI Logic rejects outright.
  await activateAivyAppCheck();
  if (kIsWeb) {
    await FirebaseAuth.instance.setPersistence(Persistence.LOCAL);
  }
  await NotificationService.instance.initialize();
  runApp(const AivyApp());
}
