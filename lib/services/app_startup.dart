import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:heaven_beverages/services/background_tracking_service.dart';

/// Heavy native setup — must not block [runApp].
class AppStartup {
  AppStartup._();

  static var _initialized = false;
  static var _initializing = false;

  static Future<void> ensureBackgroundTrackingReady() async {
    if (kIsWeb || _initialized) return;
    if (_initializing) {
      while (_initializing) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return;
    }

    _initializing = true;
    try {
      await BackgroundTrackingService.initialize().timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          debugPrint('[Startup] Background service init timed out');
        },
      );
      _initialized = true;
      debugPrint('[Startup] Background service ready');
    } catch (error, stackTrace) {
      debugPrint('[Startup] Background service init failed: $error');
      debugPrint('$stackTrace');
    } finally {
      _initializing = false;
    }
  }

  static Future<void> resumeTrackingIfOnDuty() async {
    if (kIsWeb) return;
    try {
      await ensureBackgroundTrackingReady();
      await BackgroundTrackingService.resumeIfPunchedIn().timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          debugPrint('[Startup] resumeIfPunchedIn timed out');
        },
      );
    } catch (error) {
      debugPrint('[Startup] resumeIfPunchedIn failed: $error');
    }
  }
}
