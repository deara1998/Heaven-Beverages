/// Shared attendance location tracking settings.
class TrackingConstants {
  TrackingConstants._();

  /// Interval between consecutive track_log GPS checks while punched in.
  static const trackLogInterval = Duration(seconds: 30);

  /// track_log API is sent only when moved more than this from last sent point.
  static const minTrackLogDistanceMeters = 10.0;

  /// GPS speeds below this are treated as stationary (reduces false 2–4 km/h readings).
  static const stationarySpeedThresholdMps = 1.0;
}
