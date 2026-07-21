import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:vibration/vibration.dart';

/// Reminder alarm: looping ringtone with optional fade-in. Use [stop] when the
/// popup is dismissed or the user takes an action.
class AudioService {
  AudioService._();

  static final AudioPlayer _player = AudioPlayer();

  /// True while we intend the reminder loop to be active (guards double [playReminder]).
  static bool _reminderSessionArmed = false;

  static const _primaryAssetPath = 'Ringtone/aivy.mp3';
  static const _fallbackAssetPath = 'assets/Ringtone/aivy.mp3';
  static String? _cachedRingtoneFilePath;

  /// Whether the ringtone session is active (armed and not yet [stop]ped).
  static bool get isReminderSessionActive => _reminderSessionArmed;

  static Future<void> playReminder() async {
    // ignore: avoid_print
    print('🔊 Reminder sound triggered');
    if (_reminderSessionArmed) {
      return;
    }
    if (_player.state == PlayerState.playing) {
      return;
    }
    _reminderSessionArmed = true;
    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.setVolume(1.0);
      final ringtonePath = await _ensureLocalRingtoneFile();
      await _player.play(DeviceFileSource(ringtonePath));
      unawaited(_vibrateAndroidIfAvailable());
    } catch (e, st) {
      _reminderSessionArmed = false;
      // ignore: avoid_print
      print('❌ Audio error: $e');
      debugPrint('AudioService.playReminder: $e\n$st');
    }
  }

  static Future<String> _ensureLocalRingtoneFile() async {
    final cached = _cachedRingtoneFilePath;
    if (cached != null && await File(cached).exists()) {
      return cached;
    }

    final tmpDir = await getTemporaryDirectory();
    final outPath = p.join(tmpDir.path, 'aivy_reminder.mp3');
    final outFile = File(outPath);

    try {
      final bytes = await rootBundle.load(_primaryAssetPath);
      await outFile.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
      _cachedRingtoneFilePath = outPath;
      return outPath;
    } catch (e) {
      debugPrint(
        'AudioService primary bundle asset failed ($_primaryAssetPath): $e. '
        'Trying fallback $_fallbackAssetPath',
      );
      final bytes = await rootBundle.load(_fallbackAssetPath);
      await outFile.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
      _cachedRingtoneFilePath = outPath;
      return outPath;
    }
  }

  static Future<void> _vibrateAndroidIfAvailable() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      final has = await Vibration.hasVibrator();
      if (has == true) {
        await Vibration.vibrate(pattern: [0, 500, 1000, 500]);
      }
    } catch (e, st) {
      debugPrint('AudioService vibrate: $e\n$st');
    }
  }

  static Future<void> stop() async {
    _reminderSessionArmed = false;
    try {
      await _player.stop();
      await _player.setVolume(1);
    } catch (e, st) {
      debugPrint('AudioService.stop: $e\n$st');
    }
  }
}
