import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

/// Reads live device battery for track_log API.
class DeviceTelemetry {
  DeviceTelemetry({Battery? battery}) : _battery = battery ?? Battery();

  static final DeviceTelemetry shared = DeviceTelemetry();

  final Battery _battery;

  Future<String> readBatteryPercentage() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final level = await _battery.batteryLevel;
        if (level >= 0 && level <= 100) {
          debugPrint('[Telemetry] Battery level: $level%');
          return level.toString();
        }
      } catch (error) {
        debugPrint('[Telemetry] Battery read attempt ${attempt + 1} failed: $error');
      }
      if (attempt < 2) {
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
    return '0';
  }
}
