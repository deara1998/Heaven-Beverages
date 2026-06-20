import 'package:heaven_beverages/models/user_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SessionStorage {
  static const _punchedInKey = 'attendance_is_punched_in';
  static const _punchInTimeKey = 'attendance_punch_in_time';
  static const _userIdKey = 'attendance_user_id';
  static const _sessionUserIdKey = 'session_user_id';
  static const _sessionMobileKey = 'session_mobile_no';
  static const _sessionNameKey = 'session_name';
  static const _loginResponseKey = 'login_response';
  static const _deviceIdKey = 'device_id';
  static const _lastSyncTimeKey = 'last_sync_time';
  static const _lastLatKey = 'last_lat';
  static const _lastLngKey = 'last_lng';
  static const _lastSpeedKey = 'last_speed';
  static const _lastBatteryKey = 'last_battery';

  Future<void> saveUserSession(
    UserSession session, {
    String? loginResponseRaw,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessionUserIdKey, session.userId);
    await prefs.setString(_sessionMobileKey, session.mobileNo);
    if (session.name != null) {
      await prefs.setString(_sessionNameKey, session.name!);
    } else {
      await prefs.remove(_sessionNameKey);
    }
    if (loginResponseRaw != null && loginResponseRaw.isNotEmpty) {
      await prefs.setString(_loginResponseKey, loginResponseRaw);
    }
  }

  Future<String?> loadLoginResponse() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_loginResponseKey);
  }

  Future<UserSession?> loadUserSession() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_sessionUserIdKey);
    final mobileNo = prefs.getString(_sessionMobileKey);
    if (userId == null || mobileNo == null) return null;

    return UserSession(
      userId: userId,
      mobileNo: mobileNo,
      name: prefs.getString(_sessionNameKey),
    );
  }

  Future<void> clearUserSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionUserIdKey);
    await prefs.remove(_sessionMobileKey);
    await prefs.remove(_sessionNameKey);
    await prefs.remove(_loginResponseKey);
  }

  Future<String> loadOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final deviceId = 'flutter-${DateTime.now().millisecondsSinceEpoch}';
    await prefs.setString(_deviceIdKey, deviceId);
    return deviceId;
  }

  Future<void> savePunchIn({
    required String userId,
    required DateTime punchInTime,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_punchedInKey, true);
    await prefs.setString(_punchInTimeKey, punchInTime.toIso8601String());
    await prefs.setString(_userIdKey, userId);
  }

  Future<void> clearPunchIn() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_punchedInKey);
    await prefs.remove(_punchInTimeKey);
    await prefs.remove(_userIdKey);
  }

  Future<StoredAttendanceState?> loadPunchState(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final storedUserId = prefs.getString(_userIdKey);
    if (storedUserId != userId) return null;

    final isPunchedIn = prefs.getBool(_punchedInKey) ?? false;
    if (!isPunchedIn) return null;

    final punchInTimeRaw = prefs.getString(_punchInTimeKey);
    return StoredAttendanceState(
      punchInTime: punchInTimeRaw == null
          ? null
          : DateTime.tryParse(punchInTimeRaw),
    );
  }

  Future<bool> isPunchedInForUser(String userId) async {
    final state = await loadPunchState(userId);
    return state != null;
  }

  Future<void> saveLastSync({
    required double latitude,
    required double longitude,
    required String speedKmh,
    required String batteryPercentage,
    required DateTime syncTime,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSyncTimeKey, syncTime.toIso8601String());
    await prefs.setDouble(_lastLatKey, latitude);
    await prefs.setDouble(_lastLngKey, longitude);
    await prefs.setString(_lastSpeedKey, speedKmh);
    await prefs.setString(_lastBatteryKey, batteryPercentage);
  }

  Future<StoredLocationSync?> loadLastSync() async {
    final prefs = await SharedPreferences.getInstance();
    final syncTimeRaw = prefs.getString(_lastSyncTimeKey);
    final latitude = prefs.getDouble(_lastLatKey);
    final longitude = prefs.getDouble(_lastLngKey);
    if (syncTimeRaw == null || latitude == null || longitude == null) {
      return null;
    }

    return StoredLocationSync(
      latitude: latitude,
      longitude: longitude,
      speedKmh: prefs.getString(_lastSpeedKey) ?? '0',
      batteryPercentage: prefs.getString(_lastBatteryKey) ?? '0',
      syncTime: DateTime.tryParse(syncTimeRaw),
    );
  }
}

class StoredAttendanceState {
  const StoredAttendanceState({this.punchInTime});

  final DateTime? punchInTime;
}

class StoredLocationSync {
  const StoredLocationSync({
    required this.latitude,
    required this.longitude,
    required this.speedKmh,
    required this.batteryPercentage,
    this.syncTime,
  });

  final double latitude;
  final double longitude;
  final String speedKmh;
  final String batteryPercentage;
  final DateTime? syncTime;
}
