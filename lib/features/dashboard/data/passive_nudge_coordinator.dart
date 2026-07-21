import 'package:flutter/foundation.dart';

import '../../../core/notifications/notification_service.dart';
import '../../chat/data/chat_repository.dart';
import '../models/agent_insights.dart';

/// Throttled wrapper around [NotificationService.showPassiveNudgeNotification].
///
/// Product rules enforced here:
///   * Fire at most twice per calendar day (local time).
///   * Require at least 4 hours between two nudges.
///   * Never nudge when there are no pending actions.
///
/// Throttle state is persisted under `users/{uid}/meta/nudge_state` so the
/// limit survives app restarts and cold boots.
class PassiveNudgeCoordinator {
  PassiveNudgeCoordinator({
    ChatRepository? repository,
    NotificationService? notificationService,
  }) : _repository = repository ?? ChatRepository(),
       _notificationService =
           notificationService ?? NotificationService.instance;

  final ChatRepository _repository;
  final NotificationService _notificationService;

  static const int _maxPerDay = 2;
  static const Duration _minSpacing = Duration(hours: 4);

  /// Inspects [insights] and, if the throttle allows and we have anything to
  /// nudge about, fires a local notification and writes back updated state.
  /// Returns true when a notification was dispatched.
  Future<bool> maybeNudge({
    required String userId,
    required AgentInsights insights,
  }) async {
    if (!insights.hasAnythingToNudgeAbout) {
      return false;
    }
    final pendingCount = insights.pendingActionCount;
    if (pendingCount <= 0) {
      return false;
    }

    try {
      final state = await _repository.readNudgeState(userId);
      final now = DateTime.now();
      final todayKey = _dayKey(now);

      final storedDayKey = state?['dayKey'] as String?;
      final storedCount = (state?['countToday'] as num?)?.toInt() ?? 0;
      final storedLastMs = (state?['lastSentMs'] as num?)?.toInt() ?? 0;

      final countToday = storedDayKey == todayKey ? storedCount : 0;
      if (countToday >= _maxPerDay) {
        return false;
      }

      if (storedLastMs > 0) {
        final last = DateTime.fromMillisecondsSinceEpoch(storedLastMs);
        if (now.difference(last) < _minSpacing) {
          return false;
        }
      }

      await _notificationService.showPassiveNudgeNotification(
        pendingCount: pendingCount,
      );
      await _repository.writeNudgeState(
        userId: userId,
        lastSentMs: now.millisecondsSinceEpoch,
        countToday: countToday + 1,
        dayKey: todayKey,
      );
      return true;
    } catch (error, stackTrace) {
      debugPrint('PassiveNudgeCoordinator: nudge failed: $error\n$stackTrace');
      return false;
    }
  }

  static String _dayKey(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
