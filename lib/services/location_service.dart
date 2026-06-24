import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:heaven_beverages/services/device_telemetry.dart';
import 'package:heaven_beverages/services/tracking_constants.dart';

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
    await ensureForegroundLocationPermission();
    final position = await getFreshPosition();
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

  /// Decimal places sent to server (~11 cm precision).
  static const coordinateDecimalPlaces = 6;

  static String formatCoordinate(double value) {
    return value.toStringAsFixed(coordinateDecimalPlaces);
  }

  static String formatLatitude(double latitude) => formatCoordinate(latitude);

  static String formatLongitude(double longitude) => formatCoordinate(longitude);

  static String formatCoordinatePair(double latitude, double longitude) {
    return '${formatLatitude(latitude)}, ${formatLongitude(longitude)}';
  }

  static bool hasValidCoordinates(double latitude, double longitude) {
    if (latitude < -90 || latitude > 90) return false;
    if (longitude < -180 || longitude > 180) return false;
    if (latitude == 0 && longitude == 0) return false;
    return true;
  }

  static void ensureValidCoordinates(double latitude, double longitude) {
    if (!hasValidCoordinates(latitude, longitude)) {
      throw LocationException(
        'GPS location not ready. Please wait for accurate location and try again.',
      );
    }
  }

  static Map<String, String> coordinatesForApi(double latitude, double longitude) {
    ensureValidCoordinates(latitude, longitude);
    return {
      'latitude': formatLatitude(latitude),
      'longitude': formatLongitude(longitude),
    };
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
          '[Tracking] GPS ready lat=${LocationService.formatLatitude(snapshot.latitude)} '
          'lng=${LocationService.formatLongitude(snapshot.longitude)}',
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

  Future<void> ensureForegroundLocationPermission() async {
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
  }

  @Deprecated('Use ensureForegroundLocationPermission')
  Future<void> ensureTrackingPermissions() => ensureForegroundLocationPermission();

  LocationSettings _locationSettings() {
    if (!kIsWeb && Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        timeLimit: const Duration(seconds: 30),
      );
    }
    if (!kIsWeb && Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.best,
        timeLimit: const Duration(seconds: 30),
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.best,
      timeLimit: Duration(seconds: 30),
    );
  }

  bool _isStale(Position position) {
    final age = DateTime.now().difference(position.timestamp);
    return age.inSeconds > TrackingConstants.maxGpsAgeSeconds;
  }

  bool _isLowAccuracy(Position position) {
    final accuracy = position.accuracy;
    return accuracy.isFinite && accuracy > 50;
  }

  /// Fetches a fresh GPS fix; retries if cached or low-accuracy.
  Future<Position> getFreshPosition() async {
    final settings = _locationSettings();
    var position = await Geolocator.getCurrentPosition(
      locationSettings: settings,
    );

    if (_isStale(position) || _isLowAccuracy(position)) {
      debugPrint(
        '[GPS] Retrying — age=${DateTime.now().difference(position.timestamp).inSeconds}s '
        'accuracy=${position.accuracy.toStringAsFixed(1)}m',
      );
      position = await Geolocator.getCurrentPosition(
        locationSettings: settings,
      );
    }

    ensureValidCoordinates(position.latitude, position.longitude);

    final ageSeconds = DateTime.now().difference(position.timestamp).inSeconds;
    debugPrint(
      '[GPS] lat=${formatLatitude(position.latitude)} '
      'lng=${formatLongitude(position.longitude)} '
      'accuracy=${position.accuracy.toStringAsFixed(1)}m '
      'age=${ageSeconds}s',
    );

    return position;
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
