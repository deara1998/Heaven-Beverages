import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:heaven_beverages/services/location_service.dart';
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

  /// Requests permissions — call only while the app is visible (e.g. punch in).
  static Future<TrackingPermissionResult> ensureForBackgroundTracking() async {
    if (kIsWeb) {
      return const TrackingPermissionResult(granted: true, message: 'ok');
    }

    if (!Platform.isAndroid && !Platform.isIOS) {
      return const TrackingPermissionResult(granted: true, message: 'ok');
    }

    try {
      await LocationService().ensureTrackingPermissions();
    } on LocationException catch (error) {
      return TrackingPermissionResult(granted: false, message: error.message);
    }

    if (Platform.isAndroid) {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.whileInUse) {
        final background = await Permission.locationAlways.request();
        if (!background.isGranted) {
          return const TrackingPermissionResult(
            granted: false,
            message: 'Please allow location "All the time" so tracking works '
                'when the app is closed or in background.',
          );
        }
        permission = await Geolocator.checkPermission();
      }

      if (permission != LocationPermission.always) {
        return const TrackingPermissionResult(
          granted: false,
          message: 'Background location (All the time) is required for field '
              'attendance tracking.',
        );
      }
    }

    return const TrackingPermissionResult(granted: true, message: 'ok');
  }
}
