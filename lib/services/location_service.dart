import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:heaven_beverages/services/device_telemetry.dart';
import 'package:heaven_beverages/services/tracking_constants.dart';
import 'package:permission_handler/permission_handler.dart';

class LocationSnapshot {
  const LocationSnapshot({
    required this.latitude,
    required this.longitude,
    required this.speedKmh,
    required this.batteryPercentage,
  });

  final double latitude;
  final double longitude;
  final String speedKmh;
  final String batteryPercentage;
}

class TrackLogDistanceResult {
  const TrackLogDistanceResult({
    required this.shouldSend,
    this.distanceMeters,
  });

  final bool shouldSend;
  final double? distanceMeters;
}

class LocationService {
  LocationService({DeviceTelemetry? telemetry})
      : _telemetry = telemetry ?? DeviceTelemetry.shared;

  final DeviceTelemetry _telemetry;
  int _trackingSession = 0;

  Future<LocationSnapshot> getCurrentSnapshot({
    double? lastLatitude,
    double? lastLongitude,
    DateTime? lastSyncTime,
  }) async {
    await ensureTrackingPermissions();
    final position = await _getCurrentPosition();
    return buildSnapshotFromPosition(
      position,
      lastLatitude: lastLatitude,
      lastLongitude: lastLongitude,
      lastSyncTime: lastSyncTime,
    );
  }

  Future<LocationSnapshot> buildSnapshotFromPosition(
    Position position, {
    double? lastLatitude,
    double? lastLongitude,
    DateTime? lastSyncTime,
  }) async {
    final speedKmh = resolveSpeedKmh(
      gpsSpeedMps: position.speed,
      latitude: position.latitude,
      longitude: position.longitude,
      lastLatitude: lastLatitude,
      lastLongitude: lastLongitude,
      lastSyncTime: lastSyncTime,
    );
    return LocationSnapshot(
      latitude: position.latitude,
      longitude: position.longitude,
      speedKmh: speedKmh,
      batteryPercentage: await readBatteryPercentage(),
    );
  }

  static double distanceMeters(
    double fromLat,
    double fromLng,
    double toLat,
    double toLng,
  ) {
    return Geolocator.distanceBetween(fromLat, fromLng, toLat, toLng);
  }

  static TrackLogDistanceResult evaluateTrackLogDistance({
    required double latitude,
    required double longitude,
    double? lastLatitude,
    double? lastLongitude,
  }) {
    if (lastLatitude == null || lastLongitude == null) {
      debugPrint(
        '[Tracking] Distance from last point: none (first track_log this shift)',
      );
      return const TrackLogDistanceResult(shouldSend: true);
    }

    final distance = distanceMeters(
      lastLatitude,
      lastLongitude,
      latitude,
      longitude,
    );
    final minMeters = TrackingConstants.minTrackLogDistanceMeters;
    final shouldSend = distance > minMeters;

    debugPrint(
      '[Tracking] Distance from last point: ${distance.toStringAsFixed(1)}m '
      '(required > ${minMeters.toInt()}m) → ${shouldSend ? 'SEND' : 'SKIP'} track_log',
    );

    return TrackLogDistanceResult(
      shouldSend: shouldSend,
      distanceMeters: distance,
    );
  }

  static bool shouldSendTrackLog({
    required double latitude,
    required double longitude,
    double? lastLatitude,
    double? lastLongitude,
  }) {
    return evaluateTrackLogDistance(
      latitude: latitude,
      longitude: longitude,
      lastLatitude: lastLatitude,
      lastLongitude: lastLongitude,
    ).shouldSend;
  }

  static String resolveSpeedKmh({
    required double gpsSpeedMps,
    required double latitude,
    required double longitude,
    double? lastLatitude,
    double? lastLongitude,
    DateTime? lastSyncTime,
  }) {
    if (lastLatitude != null && lastLongitude != null) {
      final distance = distanceMeters(
        lastLatitude,
        lastLongitude,
        latitude,
        longitude,
      );
      if (distance < TrackingConstants.minTrackLogDistanceMeters) {
        return '0';
      }
      if (lastSyncTime != null) {
        final elapsedMs = DateTime.now().difference(lastSyncTime).inMilliseconds;
        if (elapsedMs > 0) {
          final computedMps = distance / (elapsedMs / 1000);
          return formatSpeedKmh(computedMps);
        }
      }
    }
    return formatSpeedKmh(gpsSpeedMps);
  }

  static String formatSpeedKmh(double speedMetersPerSecond) {
    if (speedMetersPerSecond.isNaN || speedMetersPerSecond < 0) {
      return '0';
    }
    if (speedMetersPerSecond <
        TrackingConstants.stationarySpeedThresholdMps) {
      return '0';
    }
    return (speedMetersPerSecond * 3.6).toStringAsFixed(1);
  }

  Future<String> readBatteryPercentage() => _telemetry.readBatteryPercentage();

  /// Starts a chained loop: fetch latest GPS, call [onTick], wait [interval],
  /// repeat. Skips overlapping work and stops cleanly when
  /// [stopPeriodicTracking] is called.
  void startPeriodicTracking({
    Duration interval = TrackingConstants.trackLogInterval,
    required Future<void> Function(LocationSnapshot snapshot) onTick,
    void Function(Object error)? onError,
  }) {
    stopPeriodicTracking();
    final session = ++_trackingSession;
    unawaited(_runTrackingLoop(session, interval, onTick, onError));
  }

  Future<void> _runTrackingLoop(
    int session,
    Duration interval,
    Future<void> Function(LocationSnapshot snapshot) onTick,
    void Function(Object error)? onError,
  ) async {
    while (session == _trackingSession) {
      await Future.delayed(interval);
      if (session != _trackingSession) return;

      try {
        final snapshot = await getCurrentSnapshot();
        if (session != _trackingSession) return;
        debugPrint(
          '[Tracking] GPS ready lat=${snapshot.latitude} lng=${snapshot.longitude}',
        );
        await onTick(snapshot);
      } catch (error) {
        if (session != _trackingSession) return;
        onError?.call(error);
      }
    }
  }

  void stopPeriodicTracking() {
    _trackingSession++;
  }

  Future<void> ensureTrackingPermissions() async {
    if (kIsWeb) {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
      return;
    }

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw LocationException('Please turn on location services.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw LocationException('Location permission is required for attendance.');
    }
    if (permission == LocationPermission.deniedForever) {
      throw LocationException(
        'Location permission is permanently denied. Enable it in settings.',
      );
    }

    if (!kIsWeb && Platform.isAndroid &&
        permission == LocationPermission.whileInUse) {
      final backgroundStatus = await Permission.locationAlways.status;
      if (!backgroundStatus.isGranted) {
        await Permission.locationAlways.request();
      }
    }
  }

  Future<Position> _getCurrentPosition() async {
    if (kIsWeb) {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        await Geolocator.requestPermission();
      }
    }

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 15),
      ),
    );
  }

  void dispose() {
    stopPeriodicTracking();
  }
}

class LocationException implements Exception {
  LocationException(this.message);

  final String message;

  @override
  String toString() => message;
}
