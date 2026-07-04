import 'package:google_maps_flutter/google_maps_flutter.dart';

class TrackPoint {
  const TrackPoint({
    required this.latitude,
    required this.longitude,
    this.timestamp,
    this.attendanceId,
    this.speed,
    this.batteryPercentage,
  });

  final double latitude;
  final double longitude;
  final DateTime? timestamp;
  final int? attendanceId;
  final String? speed;
  final String? batteryPercentage;

  LatLng get latLng => LatLng(latitude, longitude);

  String get coordinateKey =>
      '${latitude.toStringAsFixed(5)}_${longitude.toStringAsFixed(5)}';

  String get uniqueKey {
    if (timestamp != null) {
      return '${attendanceId ?? 0}_${timestamp!.millisecondsSinceEpoch}';
    }
    return '${attendanceId ?? 0}_$coordinateKey';
  }

  TrackPoint copyWith({
    double? latitude,
    double? longitude,
    DateTime? timestamp,
    int? attendanceId,
    String? speed,
    String? batteryPercentage,
  }) {
    return TrackPoint(
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      timestamp: timestamp ?? this.timestamp,
      attendanceId: attendanceId ?? this.attendanceId,
      speed: speed ?? this.speed,
      batteryPercentage: batteryPercentage ?? this.batteryPercentage,
    );
  }
}
