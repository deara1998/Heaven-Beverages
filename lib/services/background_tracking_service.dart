import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:heaven_beverages/services/background_tracking_entry.dart';
import 'package:heaven_beverages/services/session_storage.dart';
import 'package:heaven_beverages/services/tracking_permissions.dart';

class BackgroundTrackingService {
  static const notificationChannelId = 'heaven_attendance_tracking';
  static const notificationId = 1001;

  static final FlutterLocalNotificationsPlugin notifications =
      FlutterLocalNotificationsPlugin();

  static var _configured = false;

  static Future<void> initialize() async {
    if (_configured) return;

    if (Platform.isAndroid) {
      try {
        await notifications.initialize(
          const InitializationSettings(
            android: AndroidInitializationSettings('ic_tracking_notification'),
          ),
        );

        const androidChannel = AndroidNotificationChannel(
          notificationChannelId,
          'Field Attendance Tracking',
          description: 'Silent channel for on-duty location tracking.',
          importance: Importance.low,
          playSound: false,
          showBadge: false,
        );

        await notifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.createNotificationChannel(androidChannel);
      } catch (error) {
        debugPrint('[Tracking] Notification init failed: $error');
      }
    }

    try {
      final service = FlutterBackgroundService();
      await service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: onBackgroundTrackingStart,
          autoStart: false,
          autoStartOnBoot: false,
          isForegroundMode: true,
          notificationChannelId: notificationChannelId,
          initialNotificationTitle: 'Heaven Beverages',
          initialNotificationContent: 'On duty',
          foregroundServiceNotificationId: notificationId,
          foregroundServiceTypes: [AndroidForegroundType.location],
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: onBackgroundTrackingStart,
          onBackground: _onIosBackground,
        ),
      );
      _configured = true;
    } catch (error, stackTrace) {
      _configured = false;
      debugPrint('[Tracking] Background service configure failed: $error');
      debugPrint('$stackTrace');
    }
  }

  static Future<bool> _isRunningSafe() async {
    if (!_configured) return false;
    try {
      return await FlutterBackgroundService().isRunning();
    } catch (error) {
      debugPrint('[Tracking] isRunning check failed: $error');
      return false;
    }
  }

  static Future<void> resumeIfPunchedIn() async {
    if (!await _canStartSafely()) return;
    final userId = await SessionStorage().loadActivePunchedInUserId();
    if (userId == null) return;
    await wakeUp(userId);
  }

  static Future<bool> _canStartSafely() async {
    try {
      return await TrackingPermissions.canUseBackgroundService();
    } catch (error) {
      debugPrint('[Tracking] Permission check failed: $error');
      return false;
    }
  }

  /// Keeps the background loop alive — no permission dialogs.
  static Future<void> wakeUp(String userId) async {
    if (userId.isEmpty || !await _canStartSafely()) return;
    try {
      await initialize();
      if (!_configured) return;

      final service = FlutterBackgroundService();
      if (await _isRunningSafe()) {
        service.invoke('restartTracking', {'userId': userId});
        debugPrint('[Tracking] wakeUp → restartTracking for $userId');
        return;
      }
      await start(userId);
    } catch (error, stackTrace) {
      debugPrint('[Tracking] wakeUp failed: $error');
      debugPrint('$stackTrace');
    }
  }

  static Future<bool> ensureRunning(String userId) async {
    if (!await _canStartSafely()) {
      debugPrint('[Tracking] ensureRunning skipped — permissions not ready');
      return false;
    }
    try {
      await start(userId);
      return await _isRunningSafe();
    } catch (error, stackTrace) {
      debugPrint('[Tracking] ensureRunning failed: $error');
      debugPrint('$stackTrace');
      return false;
    }
  }

  static Future<void> start(String userId, {bool callTrackLogNow = false}) async {
    if (!await _canStartSafely()) {
      debugPrint('[Tracking] start skipped — background permissions not ready');
      return;
    }

    try {
      await initialize();
      if (!_configured) return;

      final service = FlutterBackgroundService();
      final isRunning = await _isRunningSafe();

      if (!isRunning) {
        final ready = Completer<void>();
        StreamSubscription<Map<String, dynamic>?>? readySub;
        readySub = service.on('serviceReady').listen((_) {
          readySub?.cancel();
          if (!ready.isCompleted) ready.complete();
        });

        final started = await service.startService();
        debugPrint('[Tracking] startService result: $started');
        if (started != true) return;

        try {
          await ready.future.timeout(const Duration(seconds: 8));
        } catch (_) {
          debugPrint('[Tracking] serviceReady timeout — isolate may still start');
        } finally {
          await readySub.cancel();
        }
      }

      service.invoke('startTracking', {
        'userId': userId,
        'callTrackLogNow': callTrackLogNow,
      });
      debugPrint('[Tracking] Background service active for $userId');
    } catch (error, stackTrace) {
      debugPrint('[Tracking] start failed: $error');
      debugPrint('$stackTrace');
    }
  }

  static Future<void> stop() async {
    if (!_configured) return;
    try {
      if (!await _isRunningSafe()) return;

      final service = FlutterBackgroundService();
      service.invoke('stopTracking');
      await Future.delayed(const Duration(milliseconds: 300));
      service.invoke('stopService');
      debugPrint('[Tracking] Background service stopped');
    } catch (error, stackTrace) {
      debugPrint('[Tracking] stop failed: $error');
      debugPrint('$stackTrace');
    }
  }

  static Stream<Map<String, dynamic>?> syncUpdates() {
    if (!_configured) return const Stream.empty();
    try {
      return FlutterBackgroundService().on('syncUpdate');
    } catch (error) {
      debugPrint('[Tracking] syncUpdates stream failed: $error');
      return const Stream.empty();
    }
  }

  static Stream<Map<String, dynamic>?> locationUpdates() {
    if (!_configured) return const Stream.empty();
    try {
      return FlutterBackgroundService().on('locationUpdate');
    } catch (error) {
      debugPrint('[Tracking] locationUpdates stream failed: $error');
      return const Stream.empty();
    }
  }

  static Future<void> requestBatteryExemption() async {
    debugPrint('[Tracking] Battery exemption skipped (enable manually in settings if needed)');
  }

  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }
}
