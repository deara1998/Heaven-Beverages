import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:heaven_beverages/services/background_tracking_entry.dart';
import 'package:heaven_beverages/services/session_storage.dart';
import 'package:permission_handler/permission_handler.dart';

class BackgroundTrackingService {
  static const notificationChannelId = 'heaven_attendance_tracking';
  static const notificationId = 1001;

  static final FlutterLocalNotificationsPlugin notifications =
      FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    if (Platform.isAndroid) {
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
    }

    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onBackgroundTrackingStart,
        autoStart: false,
        autoStartOnBoot: true,
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
  }

  static Future<void> resumeIfPunchedIn() async {
    final userId = await SessionStorage().loadActivePunchedInUserId();
    if (userId == null) return;
    await wakeUp(userId);
  }

  /// Keeps the background loop alive — no permission dialogs.
  static Future<void> wakeUp(String userId) async {
    if (userId.isEmpty) return;
    try {
      final service = FlutterBackgroundService();
      if (await service.isRunning()) {
        service.invoke('restartTracking', {'userId': userId});
        debugPrint('[Tracking] wakeUp → restartTracking for $userId');
        return;
      }
      await start(userId);
    } catch (error) {
      debugPrint('[Tracking] wakeUp failed: $error');
    }
  }

  static Future<bool> ensureRunning(String userId) async {
    try {
      await start(userId);
      return true;
    } catch (error) {
      debugPrint('[Tracking] ensureRunning failed: $error');
      return false;
    }
  }

  static Future<void> start(String userId, {bool callTrackLogNow = false}) async {
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();

    if (!isRunning) {
      final ready = Completer<void>();
      StreamSubscription<Map<String, dynamic>?>? readySub;
      readySub = service.on('serviceReady').listen((_) {
        readySub?.cancel();
        if (!ready.isCompleted) ready.complete();
      });

      final started = await service.startService();
      debugPrint('[Tracking] startService result: $started');

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
  }

  static Future<void> stop() async {
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      service.invoke('stopTracking');
      await Future.delayed(const Duration(milliseconds: 300));
      service.invoke('stopService');
      debugPrint('[Tracking] Background service stopped');
    }
  }

  static Stream<Map<String, dynamic>?> syncUpdates() {
    return FlutterBackgroundService().on('syncUpdate');
  }

  static Stream<Map<String, dynamic>?> locationUpdates() {
    return FlutterBackgroundService().on('locationUpdate');
  }

  static Future<void> requestBatteryExemption() async {
    if (!Platform.isAndroid) return;
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (status.isGranted) return;
    await Permission.ignoreBatteryOptimizations.request();
  }

  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }
}
