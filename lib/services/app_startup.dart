import 'package:flutter/foundation.dart';

/// Heavy native setup — disabled; tracking uses foreground loop only.
class AppStartup {
  AppStartup._();

  static Future<void> ensureBackgroundTrackingReady() async {
    debugPrint('[Startup] Background init skipped (foreground tracking only)');
  }

  static Future<void> resumeTrackingIfOnDuty() async {}
}
