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
    return canUseBackgroundService();
  }

  /// True when GPS works while the app is on screen (While using / Always).
  static Future<bool> hasForegroundLocation() async {
    if (kIsWeb) return true;
    if (!Platform.isAndroid && !Platform.isIOS) return true;

    final permission = await Geolocator.checkPermission();
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  /// Background foreground-service requires "Allow all the time" + notifications.
  static Future<bool> canUseBackgroundService() async {
    if (kIsWeb) return false;
    if (!Platform.isAndroid && !Platform.isIOS) return false;

    if (Platform.isAndroid) {
      final location = await Geolocator.checkPermission();
      if (location != LocationPermission.always) return false;
      if (!await hasNotificationPermission()) return false;
    }

    return true;
  }

  static Future<bool> hasNotificationPermission() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      final status = await Permission.notification.status;
      return status.isGranted;
    } catch (error) {
      debugPrint('[Permissions] Notification check failed: $error');
      return false;
    }
  }

  /// Ask notification permission (Android 13+) — does not block punch in.
  static Future<void> requestNotificationIfNeeded() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      if (await hasNotificationPermission()) return;
      await Permission.notification.request();
    } catch (error) {
      debugPrint('[Permissions] Notification request failed: $error');
    }
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

  /// Full flow for punch in: foreground GPS first; background is optional.
  static Future<TrackingPermissionResult> ensureForBackgroundTracking() async {
    return requestForegroundLocation();
  }

  /// Optional — ask for "Allow all the time" without blocking punch in.
  static Future<TrackingPermissionResult> requestBackgroundIfNeeded() async {
    if (kIsWeb || !Platform.isAndroid) {
      return const TrackingPermissionResult(granted: true, message: 'ok');
    }

    if (await canUseBackgroundService()) {
      return const TrackingPermissionResult(granted: true, message: 'ok');
    }

    return requestBackgroundLocationSafe();
  }
}
