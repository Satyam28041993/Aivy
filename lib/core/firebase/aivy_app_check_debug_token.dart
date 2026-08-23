import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Reads the Android App Check debug secret so it can be shown on the device.
///
/// Sideloaded builds cannot use Play Integrity, so App Check falls back to the
/// debug provider, whose secret must be registered in Firebase Console. The
/// provider only ever prints it to logcat, which otherwise means connecting the
/// phone to a computer just to copy one string.
class AivyAppCheckDebugToken {
  const AivyAppCheckDebugToken._();

  static const _channel = MethodChannel('aivy/app_check_debug');

  /// The debug secret, or null on other platforms and when it has not been
  /// logged yet (the log buffer is rotated, so this can miss on a long-running
  /// app -- restarting it logs the secret again).
  static Future<String?> read() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    try {
      return await _channel.invokeMethod<String>('debugToken');
    } catch (e) {
      debugPrint('[AppCheck] debug token read failed: $e');
      return null;
    }
  }
}
