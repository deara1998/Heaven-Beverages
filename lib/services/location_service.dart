import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
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

class LocationService {
  LocationService({Battery? battery}) : _battery = battery ?? Battery();

  final Battery _battery;
  Timer? _trackingTimer;

  Future<LocationSnapshot> getCurrentSnapshot() async {
    await ensureTrackingPermissions();
    final position = await _getCurrentPosition();
    return LocationSnapshot(
      latitude: position.latitude,
      longitude: position.longitude,
      speedKmh: _formatSpeed(position.speed),
      batteryPercentage: await _readBatteryLevel(),
    );
  }

  void startPeriodicTracking({
    required Duration interval,
    required Future<void> Function(LocationSnapshot snapshot) onTick,
    void Function(Object error)? onError,
  }) {
    _trackingTimer?.cancel();
    var isTickRunning = false;
    _trackingTimer = Timer.periodic(interval, (_) async {
      if (isTickRunning) return;
      isTickRunning = true;
      try {
        final snapshot = await getCurrentSnapshot();
        await onTick(snapshot);
      } catch (error) {
        onError?.call(error);
      } finally {
        isTickRunning = false;
      }
    });
  }

  void stopPeriodicTracking() {
    _trackingTimer?.cancel();
    _trackingTimer = null;
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

  Future<String> _readBatteryLevel() async {
    try {
      final level = await _battery.batteryLevel;
      return level.toString();
    } catch (_) {
      return '100';
    }
  }

  String _formatSpeed(double speedMetersPerSecond) {
    if (speedMetersPerSecond.isNaN || speedMetersPerSecond < 0) {
      return '0';
    }
    return (speedMetersPerSecond * 3.6).toStringAsFixed(1);
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
