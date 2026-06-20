class AttendanceLogEntry {
  const AttendanceLogEntry({
    required this.time,
    required this.action,
    required this.latitude,
    required this.longitude,
    this.message,
    this.success = true,
  });

  final DateTime time;
  final String action;
  final double latitude;
  final double longitude;
  final String? message;
  final bool success;
}
