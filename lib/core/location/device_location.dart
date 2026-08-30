import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Where the phone says it is, for the agent.
///
/// Every method here answers with `null` rather than throwing. A location is a
/// convenience — it makes "paas me" and "yahan se" work without being told —
/// and a message must never fail to send because the GPS was slow, the
/// permission was declined, or the device has no fix at all.
class DeviceLocation {
  DeviceLocation._();

  /// A fix younger than this is reused as-is: asking the GPS again for a
  /// question typed thirty seconds later buys nothing but delay.
  static const Duration _freshFor = Duration(minutes: 3);

  /// How long a message will wait for a fresh fix before going without one.
  static const Duration _timeout = Duration(seconds: 6);

  static Position? _cached;
  static DateTime? _cachedAt;

  static bool get _cacheIsFresh {
    final at = _cachedAt;
    return at != null && DateTime.now().difference(at) < _freshFor;
  }

  /// Asks for permission if it has not been decided yet.
  ///
  /// Returns true when the app may read the location. Called once when the
  /// agent screen opens, so the system dialog appears with the screen that
  /// needs it rather than at launch.
  static Future<bool> ensurePermission() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[Aivy] location permission check failed: $error');
      }
      return false;
    }
  }

  /// The current position, or null if it cannot be had quickly.
  ///
  /// Order matters: a cached fix, then the OS's last known position, then a
  /// fresh reading. The middle step is what keeps the first message of a
  /// session from waiting on a cold GPS.
  static Future<Position?> current() async {
    if (_cacheIsFresh) {
      return _cached;
    }
    try {
      // The service check is skipped on web: browsers have no such switch and
      // the plugin reports it as disabled, which used to abort every fix before
      // the browser was ever asked.
      if (!kIsWeb && !await Geolocator.isLocationServiceEnabled()) {
        return _cached;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        // Asking here as well as at screen open: on the web the prompt only
        // appears on a real user gesture, and the first message is one.
        permission = await Geolocator.requestPermission();
      }
      final granted = permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
      if (!granted) {
        return null;
      }

      // Not on web: browsers keep no last-known fix, and the plugin throws
      // rather than returning null there.
      final last = kIsWeb ? null : await Geolocator.getLastKnownPosition();
      if (last != null) {
        _remember(last);
        // Warm the cache for the next message without holding this one up.
        unawaited(_refreshInBackground());
        return last;
      }

      final fresh = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: _timeout,
        ),
      ).timeout(_timeout);
      _remember(fresh);
      return fresh;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[Aivy] location unavailable: $error');
      }
      return _cached;
    }
  }

  static Future<void> _refreshInBackground() async {
    try {
      final fresh = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: _timeout,
        ),
      ).timeout(_timeout);
      _remember(fresh);
    } catch (_) {
      // The cached fix stays; nothing here is worth surfacing.
    }
  }

  static void _remember(Position p) {
    _cached = p;
    _cachedAt = DateTime.now();
  }
}
