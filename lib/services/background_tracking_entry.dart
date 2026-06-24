import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:heaven_beverages/services/attendance_service.dart';
import 'package:heaven_beverages/services/device_telemetry.dart';
import 'package:heaven_beverages/services/location_service.dart';
import 'package:heaven_beverages/services/session_storage.dart';
import 'package:heaven_beverages/services/tracking_constants.dart';

/// Top-level entry point required by flutter_background_service background isolate.
@pragma('vm:entry-point')
void onBackgroundTrackingStart(ServiceInstance service) {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  _BackgroundTrackingRunner(service).attach();
}

class _BackgroundTrackingRunner {
  _BackgroundTrackingRunner(this.service);

  final ServiceInstance service;
  static const _trackInterval = TrackingConstants.trackLogInterval;

  int _trackingSessionId = 0;
  String? _activeUserId;
  var _isSendingTrackLog = false;
  var _isLoopRunning = false;
  var _foregroundActive = false;

  final _sessionStorage = SessionStorage();
  final _attendanceService = AttendanceService();
  final _locationService = LocationService();

  void attach() {
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    await _ensureForegroundOnce();

    service.on('startTracking').listen((event) async {
      final userId = event?['userId']?.toString();
      if (userId == null || userId.isEmpty) return;
      final callTrackLogNow = event?['callTrackLogNow'] == true;
      await _beginTracking(userId, callTrackLogNow: callTrackLogNow);
    });

    service.on('restartTracking').listen((event) async {
      final userId = event?['userId']?.toString() ??
          await _sessionStorage.loadActivePunchedInUserId();
      if (userId == null || userId.isEmpty) return;
      debugPrint('[Tracking] restartTracking received for $userId');
      await _beginTracking(userId, callTrackLogNow: false, force: true);
    });

    service.on('stopTracking').listen((_) {
      _trackingSessionId++;
      _activeUserId = null;
      _isLoopRunning = false;
      debugPrint('[Tracking] Background loop stopped');
    });

    service.on('stopService').listen((_) {
      _trackingSessionId++;
      _activeUserId = null;
      _isLoopRunning = false;
      service.stopSelf();
    });

    service.invoke('serviceReady');

    final userId = await _sessionStorage.loadActivePunchedInUserId();
    if (userId != null) {
      await _beginTracking(userId, callTrackLogNow: true);
    }
  }

  /// Android requires a foreground service while tracking; set once, never update.
  Future<void> _ensureForegroundOnce() async {
    if (_foregroundActive || service is! AndroidServiceInstance) return;

    final android = service as AndroidServiceInstance;
    await android.setAsForegroundService();
    await android.setForegroundNotificationInfo(
      title: 'Heaven Beverages',
      content: 'On duty',
    );
    _foregroundActive = true;
  }

  Future<void> _beginTracking(
    String userId, {
    required bool callTrackLogNow,
    bool force = false,
  }) async {
    if (!force && _activeUserId == userId && _isLoopRunning) {
      if (callTrackLogNow) {
        await _sendTrackLog(userId);
      }
      return;
    }

    _trackingSessionId++;
    final sessionId = _trackingSessionId;
    _activeUserId = userId;

    await _ensureForegroundOnce();
    debugPrint('[Tracking] Background loop started for user $userId');

    unawaited(
      _runTrackingLoop(
        userId,
        sessionId,
        callTrackLogNow: callTrackLogNow,
      ),
    );
  }

  Future<void> _runTrackingLoop(
    String userId,
    int sessionId, {
    required bool callTrackLogNow,
  }) async {
    _isLoopRunning = true;
    try {
      if (callTrackLogNow) {
        await _sendTrackLog(userId);
      }

      while (_trackingSessionId == sessionId && _activeUserId == userId) {
        await Future.delayed(_trackInterval);
        if (_trackingSessionId != sessionId || _activeUserId != userId) return;
        await _sendTrackLog(userId);
      }
    } finally {
      if (_trackingSessionId == sessionId) {
        _isLoopRunning = false;
      }
    }
  }

  Future<void> _sendTrackLog(String userId) async {
    if (_isSendingTrackLog || _activeUserId != userId) return;
    _isSendingTrackLog = true;

    try {
      if (!await _sessionStorage.isPunchedInForUser(userId)) {
        _activeUserId = null;
        _trackingSessionId++;
        service.invoke('stopService');
        return;
      }

      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw LocationException('Location services are off.');
      }

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw LocationException('Location permission missing.');
      }

      final lastSent = await _sessionStorage.loadLastSync();

      final position = await _locationService.getFreshPosition();

      if (_activeUserId != userId) return;

      final snapshot = await _locationService.buildSnapshotFromPosition(
        position,
        lastLatitude: lastSent?.latitude,
        lastLongitude: lastSent?.longitude,
        lastSyncTime: lastSent?.syncTime,
      );
      final batteryPercentage = await DeviceTelemetry.shared.readBatteryPercentage();
      final trackSnapshot = LocationSnapshot(
        latitude: snapshot.latitude,
        longitude: snapshot.longitude,
        speedKmh: snapshot.speedKmh,
        batteryPercentage: batteryPercentage,
      );

      final distanceCheck = await _sessionStorage.evaluateTrackLogAt(
        trackSnapshot.latitude,
        trackSnapshot.longitude,
      );
      if (!distanceCheck.shouldSend) {
        service.invoke('locationUpdate', {
          'latitude': trackSnapshot.latitude,
          'longitude': trackSnapshot.longitude,
          'speedKmh': trackSnapshot.speedKmh,
          'batteryPercentage': batteryPercentage,
        });
        return;
      }

      LocationService.ensureValidCoordinates(
        trackSnapshot.latitude,
        trackSnapshot.longitude,
      );
      final coords = LocationService.coordinatesForApi(
        trackSnapshot.latitude,
        trackSnapshot.longitude,
      );
      debugPrint(
        '[Tracking] Background track_log lat=${coords['latitude']} '
        'lng=${coords['longitude']} speed=${trackSnapshot.speedKmh}km/h '
        'battery=$batteryPercentage%',
      );

      final result = await _attendanceService.trackLogLocation(
        userId: userId,
        latitude: coords['latitude']!,
        longitude: coords['longitude']!,
        speed: trackSnapshot.speedKmh,
        batteryPercentage: batteryPercentage,
      );

      final syncTime = DateTime.now();
      if (result.isSuccess) {
        await _sessionStorage.saveLastSync(
          latitude: trackSnapshot.latitude,
          longitude: trackSnapshot.longitude,
          speedKmh: trackSnapshot.speedKmh,
          batteryPercentage: batteryPercentage,
          syncTime: syncTime,
        );
      }

      service.invoke('syncUpdate', {
        'latitude': trackSnapshot.latitude,
        'longitude': trackSnapshot.longitude,
        'speedKmh': trackSnapshot.speedKmh,
        'batteryPercentage': batteryPercentage,
        'syncTime': syncTime.toIso8601String(),
        'success': result.isSuccess,
        'message': result.message ?? result.raw,
      });
    } catch (error) {
      debugPrint('[Tracking] Background track_log failed: $error');
      service.invoke('syncUpdate', {
        'success': false,
        'message': error.toString(),
      });
    } finally {
      _isSendingTrackLog = false;
    }
  }
}
