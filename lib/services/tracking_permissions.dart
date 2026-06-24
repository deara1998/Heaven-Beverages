import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

class TrackingPermissionResult {
  const TrackingPermissionResult({
    required this.granted,
    required this.message,
  });

  final bool granted;
  final String message;
}

class TrackingPermissions {
  TrackingPermissions._();

  /// Silent check — never shows permission dialogs (safe when app is in background).
  static Future<bool> hasBackgroundTrackingPermissions() async {
    if (kIsWeb) return true;
    if (!Platform.isAndroid && !Platform.isIOS) return true;

    if (Platform.isAndroid) {
      final location = await Geolocator.checkPermission();
      if (location != LocationPermission.always) return false;
    }

    return true;
  }

  /// Runtime GPS permission — ask "While using the app" first.
  static Future<TrackingPermissionResult> requestForegroundLocation() async {
    if (kIsWeb) {
      return const TrackingPermissionResult(granted: true, message: 'ok');
    }

    if (!Platform.isAndroid && !Platform.isIOS) {
      return const TrackingPermissionResult(granted: true, message: 'ok');
    }

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return const TrackingPermissionResult(
          granted: false,
          message: 'Please turn ON location / GPS in your phone settings.',
        );
      }

      var permission = await Geolocator.checkPermission();
      debugPrint('[Permissions] Current location permission: $permission');

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        debugPrint('[Permissions] After request: $permission');
      }

      if (permission == LocationPermission.denied) {
        return const TrackingPermissionResult(
          granted: false,
          message: 'Location permission is required for attendance.',
        );
      }

      if (permission == LocationPermission.deniedForever) {
        return const TrackingPermissionResult(
          granted: false,
          message:
              'Location permission is blocked. Enable it in App Settings → Permissions → Location.',
        );
      }

      return const TrackingPermissionResult(granted: true, message: 'ok');
    } catch (error, stackTrace) {
      debugPrint('[Permissions] Foreground location request failed: $error');
      debugPrint('$stackTrace');
      return TrackingPermissionResult(
        granted: false,
        message: 'Could not request location permission. Please enable GPS in settings.',
      );
    }
  }

  /// "Allow all the time" — separate step after foreground (avoids OPPO crash).
  static Future<TrackingPermissionResult> requestBackgroundLocationSafe() async {
    if (kIsWeb || !Platform.isAndroid) {
      return const TrackingPermissionResult(granted: true, message: 'ok');
    }

    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.always) {
        return const TrackingPermissionResult(granted: true, message: 'ok');
      }

      if (permission != LocationPermission.whileInUse) {
        return const TrackingPermissionResult(
          granted: false,
          message: 'Allow location "While using the app" first, then try Punch In again.',
        );
      }

      // Wait for the first permission dialog to fully close (OPPO/ColorOS crash fix).
      await Future.delayed(const Duration(milliseconds: 800));

      final current = await Permission.locationAlways.status;
      if (current.isGranted) {
        return const TrackingPermissionResult(granted: true, message: 'ok');
      }

      PermissionStatus result;
      try {
        result = await Permission.locationAlways.request();
        debugPrint('[Permissions] Background location result: $result');
      } catch (error) {
        debugPrint('[Permissions] Background location dialog error: $error');
        result = PermissionStatus.denied;
      }

      permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.always || result.isGranted) {
        return const TrackingPermissionResult(granted: true, message: 'ok');
      }

      return const TrackingPermissionResult(
        granted: false,
        message: 'For field tracking, open Settings → Apps → Heaven Beverages → '
            'Location → select "Allow all the time".',
      );
    } catch (error, stackTrace) {
      debugPrint('[Permissions] Background location failed: $error');
      debugPrint('$stackTrace');
      return const TrackingPermissionResult(
        granted: false,
        message: 'Could not request background location. Enable "Allow all the time" in settings.',
      );
    }
  }

  /// Full flow for punch in: foreground GPS → then background (all the time).
  static Future<TrackingPermissionResult> ensureForBackgroundTracking() async {
    if (kIsWeb) {
      return const TrackingPermissionResult(granted: true, message: 'ok');
    }

    if (!Platform.isAndroid && !Platform.isIOS) {
      return const TrackingPermissionResult(granted: true, message: 'ok');
    }

    final foreground = await requestForegroundLocation();
    if (!foreground.granted) return foreground;

    if (Platform.isAndroid) {
      return requestBackgroundLocationSafe();
    }

    return const TrackingPermissionResult(granted: true, message: 'ok');
  }
}
