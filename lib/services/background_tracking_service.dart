import 'dart:async';

import 'package:flutter/foundation.dart';

/// Background foreground-service is disabled for release stability.
/// Tracking runs in the main isolate via [LocationService.startPeriodicTracking].
class BackgroundTrackingService {
  static var _configured = false;

  static Future<void> initialize() async {
    _configured = true;
    debugPrint('[Tracking] Background service disabled — using foreground loop only');
  }

  static Future<void> resumeIfPunchedIn() async {}

  static Future<void> wakeUp(String userId) async {}

  static Future<bool> ensureRunning(String userId) async => false;

  static Future<void> start(String userId, {bool callTrackLogNow = false}) async {}

  static Future<void> stop() async {}

  static Stream<Map<String, dynamic>?> syncUpdates() => const Stream.empty();

  static Stream<Map<String, dynamic>?> locationUpdates() => const Stream.empty();

  static Future<void> requestBatteryExemption() async {}

  static bool get isConfigured => _configured;
}
