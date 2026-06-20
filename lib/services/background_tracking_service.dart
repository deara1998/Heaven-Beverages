import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:heaven_beverages/services/attendance_service.dart';
import 'package:heaven_beverages/services/location_service.dart';
import 'package:heaven_beverages/services/session_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BackgroundTrackingService {
  static const _notificationChannelId = 'heaven_attendance_tracking';
  static const _trackInterval = Duration(seconds: 20);

  static Future<void> initialize() async {
    final notifications = FlutterLocalNotificationsPlugin();
    const androidChannel = AndroidNotificationChannel(
      _notificationChannelId,
      'Attendance Tracking',
      description: 'Keeps location tracking active while you are punched in.',
      importance: Importance.low,
    );

    await notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);

    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onServiceStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: _notificationChannelId,
        initialNotificationTitle: 'Heaven Beverages',
        initialNotificationContent: 'Attendance tracking is active',
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onServiceStart,
        onBackground: _onIosBackground,
      ),
    );
  }

  static Future<void> start(String userId, {bool callTrackLogNow = false}) async {
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    }
    service.invoke('startTracking', {
      'userId': userId,
      'callTrackLogNow': callTrackLogNow,
    });
  }

  static Future<void> stop() async {
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      service.invoke('stopTracking');
      service.invoke('stopService');
    }
  }

  static Stream<Map<String, dynamic>?> syncUpdates() {
    return FlutterBackgroundService().on('syncUpdate');
  }

  @pragma('vm:entry-point')
  static Future<bool> _onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }

  @pragma('vm:entry-point')
  static void _onServiceStart(ServiceInstance service) {
    DartPluginRegistrant.ensureInitialized();

    Timer? trackingTimer;
    String? activeUserId;
    var isSendingTrackLog = false;
    final sessionStorage = SessionStorage();
    final attendanceService = AttendanceService();

    Future<void> sendTrackLog(String userId) async {
      if (isSendingTrackLog) return;
      isSendingTrackLog = true;

      try {
        final isPunchedIn = await sessionStorage.isPunchedInForUser(userId);
        if (!isPunchedIn) {
          trackingTimer?.cancel();
          activeUserId = null;
          service.invoke('stopService');
          return;
        }

        await _ensureBackgroundLocationPermission();
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 15),
          ),
        );

        final result = await attendanceService.trackLogLocation(
          userId: userId,
          latitude: position.latitude.toString(),
          longitude: position.longitude.toString(),
        );

        final syncTime = DateTime.now();
        await sessionStorage.saveLastSync(
          latitude: position.latitude,
          longitude: position.longitude,
          speedKmh: '0',
          batteryPercentage: '0',
          syncTime: syncTime,
        );

        if (service is AndroidServiceInstance) {
          await service.setForegroundNotificationInfo(
            title: 'Heaven Beverages',
            content: result.isSuccess
                ? 'Last sync ${syncTime.hour.toString().padLeft(2, '0')}:'
                    '${syncTime.minute.toString().padLeft(2, '0')}'
                : 'Tracking active • retrying on next interval',
          );
        }

        service.invoke('syncUpdate', {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'speedKmh': '0',
          'batteryPercentage': '0',
          'syncTime': syncTime.toIso8601String(),
          'success': result.isSuccess,
          'message': result.message ?? result.raw,
        });
      } catch (error) {
        service.invoke('syncUpdate', {
          'success': false,
          'message': error.toString(),
        });
      } finally {
        isSendingTrackLog = false;
      }
    }

    Future<void> beginTracking(
      String userId, {
      bool callTrackLogNow = false,
    }) async {
      activeUserId = userId;
      trackingTimer?.cancel();

      if (service is AndroidServiceInstance) {
        await service.setAsForegroundService();
        await service.setForegroundNotificationInfo(
          title: 'Heaven Beverages',
          content: 'Attendance tracking active • every 20 sec',
        );
      }

      if (callTrackLogNow) {
        await sendTrackLog(userId);
      }

      trackingTimer = Timer.periodic(_trackInterval, (_) {
        final currentUserId = activeUserId;
        if (currentUserId != null) {
          sendTrackLog(currentUserId);
        }
      });
    }

    service.on('startTracking').listen((event) async {
      final userId = event?['userId']?.toString();
      if (userId == null || userId.isEmpty) return;
      final callTrackLogNow = event?['callTrackLogNow'] == true;
      await beginTracking(userId, callTrackLogNow: callTrackLogNow);
    });

    service.on('stopTracking').listen((_) {
      trackingTimer?.cancel();
      trackingTimer = null;
      activeUserId = null;
    });

    service.on('stopService').listen((_) {
      trackingTimer?.cancel();
      service.stopSelf();
    });

    Future<void> restoreTrackingIfNeeded() async {
      final prefs = await SharedPreferences.getInstance();
      final isPunchedIn = prefs.getBool('attendance_is_punched_in') ?? false;
      final userId = prefs.getString('attendance_user_id');
      if (isPunchedIn && userId != null && userId.isNotEmpty) {
        await beginTracking(userId, callTrackLogNow: true);
      }
    }

    unawaited(restoreTrackingIfNeeded());
  }

  static Future<void> _ensureBackgroundLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw LocationException('Please turn on location services.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw LocationException('Location permission is required for attendance.');
    }

    if (permission == LocationPermission.whileInUse) {
      final backgroundStatus = await Permission.locationAlways.status;
      if (!backgroundStatus.isGranted) {
        await Permission.locationAlways.request();
      }
    }
  }
}
