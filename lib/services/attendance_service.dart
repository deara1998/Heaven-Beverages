import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:xml/xml.dart';

import 'api_client.dart';
import 'api_config.dart';
import 'soap_utils.dart';

class AttendanceService {
  AttendanceService({ApiClient? apiClient}) : _apiClient = apiClient ?? ApiClient();

  final ApiClient _apiClient;

  Future<AttendanceResult> punchIn({
    required String userId,
    required String latitude,
    required String longitude,
    String lang = 'en',
  }) {
    return _call(
      operation: 'punch_in',
      resultTag: 'punch_inResult',
      body: '''
    <punch_in xmlns="${ApiConfig.namespace}">
      <user_id>${SoapUtils.escapeXml(userId)}</user_id>
      <latitude>${SoapUtils.escapeXml(latitude)}</latitude>
      <longitude>${SoapUtils.escapeXml(longitude)}</longitude>
      <lang>${SoapUtils.escapeXml(lang)}</lang>
    </punch_in>''',
    );
  }

  Future<AttendanceResult> punchOut({
    required String userId,
    required String latitude,
    required String longitude,
    String lang = 'en',
  }) {
    return _call(
      operation: 'punch_out',
      resultTag: 'punch_outResult',
      body: '''
    <punch_out xmlns="${ApiConfig.namespace}">
      <user_id>${SoapUtils.escapeXml(userId)}</user_id>
      <latitude>${SoapUtils.escapeXml(latitude)}</latitude>
      <longitude>${SoapUtils.escapeXml(longitude)}</longitude>
      <lang>${SoapUtils.escapeXml(lang)}</lang>
    </punch_out>''',
    );
  }

  Future<AttendanceResult> trackLog({
    required String userId,
    required String latitude,
    required String longitude,
    String speed = '0',
    String batteryPercentage = '0',
    String lang = 'en',
  }) {
    return _call(
      operation: 'track_log',
      resultTag: 'track_logResult',
      body: '''
    <track_log xmlns="${ApiConfig.namespace}">
      <user_id>${SoapUtils.escapeXml(userId)}</user_id>
      <latitude>${SoapUtils.escapeXml(latitude)}</latitude>
      <longitude>${SoapUtils.escapeXml(longitude)}</longitude>
      <speed>${SoapUtils.escapeXml(speed)}</speed>
      <battery_percentage>${SoapUtils.escapeXml(batteryPercentage)}</battery_percentage>
      <lang>${SoapUtils.escapeXml(lang)}</lang>
    </track_log>''',
    );
  }

  Future<AttendanceResult> trackLogLocation({
    required String userId,
    required String latitude,
    required String longitude,
    String speed = '0',
    String batteryPercentage = '0',
    String lang = 'en',
  }) {
    return trackLog(
      userId: userId,
      latitude: latitude,
      longitude: longitude,
      speed: speed,
      batteryPercentage: batteryPercentage,
      lang: lang,
    );
  }

  Future<StaffDashboardResult> staffDashboard({
    required String userId,
    String? tripDate,
    String lang = 'en',
  }) {
    return _callDashboard(
      userId: userId,
      tripDate: tripDate ?? '',
      lang: lang,
    );
  }

  Future<StaffDashboardResult> _callDashboard({
    required String userId,
    required String tripDate,
    required String lang,
  }) async {
    final envelope = SoapUtils.buildEnvelope(
      namespace: ApiConfig.namespace,
      apiUserName: ApiConfig.apiUserName,
      apiPassword: ApiConfig.apiPassword,
      body: '''
    <staff_dashboard xmlns="${ApiConfig.namespace}">
      <user_id>${SoapUtils.escapeXml(userId)}</user_id>
      <trip_date>${SoapUtils.escapeXml(tripDate)}</trip_date>
      <lang>${SoapUtils.escapeXml(lang)}</lang>
    </staff_dashboard>''',
    );

    final response = await _apiClient.post(
      operation: 'staff_dashboard',
      url: Uri.parse(ApiConfig.baseUrl),
      headers: ApiClient.soapHeaders('staff_dashboard'),
      body: envelope,
    );

    if (response.statusCode != 200) {
      throw AttendanceException(
        'staff_dashboard failed with status ${response.statusCode}',
      );
    }

    return _parseDashboardResponse(response.body);
  }

  StaffDashboardResult _parseDashboardResponse(String body) {
    final document = XmlDocument.parse(body);
    final resultElement =
        document.findAllElements('staff_dashboardResult').firstOrNull;

    if (resultElement == null) {
      throw AttendanceException('Invalid response from server');
    }

    final rawResult = resultElement.innerText.trim();
    if (rawResult.isEmpty) {
      throw AttendanceException('Empty response from server');
    }

    try {
      final decoded = jsonDecode(rawResult);
      if (decoded is Map<String, dynamic>) {
        return StaffDashboardResult.fromJson(decoded, rawResult);
      }
    } on FormatException {
      // Response may be plain text instead of JSON.
    }

    return StaffDashboardResult(raw: rawResult);
  }

  Future<AttendanceResult> _call({
    required String operation,
    required String resultTag,
    required String body,
  }) async {
    final envelope = SoapUtils.buildEnvelope(
      namespace: ApiConfig.namespace,
      apiUserName: ApiConfig.apiUserName,
      apiPassword: ApiConfig.apiPassword,
      body: body,
    );

    final response = await _apiClient.post(
      operation: operation,
      url: Uri.parse(ApiConfig.baseUrl),
      headers: ApiClient.soapHeaders(operation),
      body: envelope,
    );

    if (response.statusCode != 200) {
      throw AttendanceException(
        '$operation failed with status ${response.statusCode}',
      );
    }

    return _parseResponse(response.body, resultTag);
  }

  AttendanceResult _parseResponse(String body, String resultTag) {
    final document = XmlDocument.parse(body);
    final resultElement = document.findAllElements(resultTag).firstOrNull;

    if (resultElement == null) {
      throw AttendanceException('Invalid response from server');
    }

    final rawResult = resultElement.innerText.trim();
    if (rawResult.isEmpty) {
      throw AttendanceException('Empty response from server');
    }

    try {
      final decoded = jsonDecode(rawResult);
      if (decoded is Map<String, dynamic>) {
        return AttendanceResult.fromJson(decoded, rawResult);
      }
    } on FormatException {
      // Response may be plain text instead of JSON.
    }

    return AttendanceResult(raw: rawResult);
  }

  void dispose() {
    _apiClient.dispose();
  }
}

class AttendanceResult {
  const AttendanceResult({
    required this.raw,
    this.success,
    this.message,
    this.data,
  });

  factory AttendanceResult.fromJson(Map<String, dynamic> json, String raw) {
    final successValue =
        json['success'] ?? json['Success'] ?? json['status'] ?? json['Status'];
    final messageValue =
        json['message'] ?? json['Message'] ?? json['msg'] ?? json['Msg'];

    return AttendanceResult(
      raw: raw,
      success: _parseBool(successValue),
      message: messageValue?.toString(),
      data: json,
    );
  }

  final String raw;
  final bool? success;
  final String? message;
  final Map<String, dynamic>? data;

  bool get isSuccess {
    if (success != null) return success!;
    final lower = raw.toLowerCase();
    return lower.contains('"success":"1"') ||
        lower.contains('"success":1') ||
        lower.contains('"success":true') ||
        lower.contains('"status":"success"') ||
        lower.contains('"status":1') ||
        lower.contains('success');
  }

  static bool? _parseBool(dynamic value) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is num) return value == 1;
    final text = value.toString().toLowerCase();
    if (text == 'true' || text == 'success' || text == '1') return true;
    if (text == 'false' || text == 'fail' || text == '0') return false;
    return null;
  }
}

class AttendanceException implements Exception {
  AttendanceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class StaffDashboardResult {
  const StaffDashboardResult({
    required this.raw,
    this.success,
    this.message,
    this.todayStatus,
    this.isPunchedIn,
    this.punchInTime,
    this.data,
    this.record,
  });

  factory StaffDashboardResult.fromJson(Map<String, dynamic> json, String raw) {
    final resultBlock = json['result'] ?? json['Result'];
    final profile = _extractProfile(resultBlock);
    final sessions = _extractSessions(resultBlock);

    final sessionDuty = _resolveFromLastSession(sessions);
    final todayStatus = _readString(profile, const [
      'TodayStatus',
      'today_status',
      'todayStatus',
    ]);
    final isPunchedIn = sessionDuty ?? _resolveFromProfile(profile, todayStatus);

    final punchInTime = _readDateTime(profile, const [
      'CurrentPunchInTime',
      'current_punch_in_time',
      'FirstPunchIn',
      'first_punch_in',
    ]) ?? _punchInTimeFromLastLiveSession(sessions);

    return StaffDashboardResult(
      raw: raw,
      success: _parseBool(
        json['success'] ?? json['Success'] ?? json['status'] ?? json['Status'],
      ),
      message: _readString(json, const ['message', 'Message', 'msg', 'Msg']),
      todayStatus: todayStatus ?? _statusLabelFromDuty(isPunchedIn),
      isPunchedIn: isPunchedIn,
      punchInTime: punchInTime,
      data: json,
      record: profile,
    );
  }

  final String raw;
  final bool? success;
  final String? message;
  final String? todayStatus;
  final bool? isPunchedIn;
  final DateTime? punchInTime;
  final Map<String, dynamic>? data;
  final Map<String, dynamic>? record;

  /// True when last session is Live / open (no punch out).
  bool get isLive => isPunchedIn ?? todayStatus?.trim().toLowerCase() == 'live';

  bool get isOnDuty => isLive;

  bool get isSuccess {
    if (success != null) return success!;
    final lower = raw.toLowerCase();
    return lower.contains('"success":"1"') ||
        lower.contains('"success":1') ||
        lower.contains('"success":true') ||
        lower.contains('"status":"success"') ||
        lower.contains('"status":1');
  }

  static Map<String, dynamic>? _extractProfile(dynamic resultBlock) {
    if (resultBlock is! Map) return null;

    final map = resultBlock is Map<String, dynamic>
        ? resultBlock
        : Map<String, dynamic>.from(resultBlock);

    final profile = map['profile'] ?? map['Profile'];
    if (profile is List && profile.isNotEmpty) {
      final first = profile.first;
      if (first is Map<String, dynamic>) return first;
      if (first is Map) return Map<String, dynamic>.from(first);
    }
    if (profile is Map<String, dynamic>) return profile;
    if (profile is Map) return Map<String, dynamic>.from(profile);

    return map;
  }

  static List<Map<String, dynamic>> _extractSessions(dynamic resultBlock) {
    if (resultBlock is! Map) return const [];

    final map = resultBlock is Map<String, dynamic>
        ? resultBlock
        : Map<String, dynamic>.from(resultBlock);

    final sessions = map['sessions'] ?? map['Sessions'];
    if (sessions is! List) return const [];

    return sessions
        .whereType<Map>()
        .map((session) => Map<String, dynamic>.from(session))
        .toList();
  }

  /// Last session decides button: Live / no punch-out → Punch Out, else Punch In.
  static bool? _resolveFromLastSession(List<Map<String, dynamic>> sessions) {
    if (sessions.isEmpty) return null;

    final last = sessions.last;
    final sessionStatus =
        _readString(last, const ['SessionStatus', 'session_status'])
            ?.toLowerCase();

    if (sessionStatus == 'live') return true;
    if (sessionStatus == 'completed' ||
        sessionStatus == 'closed' ||
        sessionStatus == 'out') {
      return false;
    }

    final punchOut = last['PunchOutTime'] ?? last['punch_out_time'];
    if (punchOut == null) return true;
    final punchOutText = punchOut.toString().trim();
    if (punchOutText.isEmpty || punchOutText.toLowerCase() == 'null') {
      return true;
    }

    return false;
  }

  static bool? _resolveFromProfile(
    Map<String, dynamic>? profile,
    String? todayStatus,
  ) {
    if (todayStatus != null && todayStatus.trim().isNotEmpty) {
      final normalized = todayStatus.trim().toLowerCase();
      if (normalized == 'live') return true;
      if (normalized == 'out' ||
          normalized == 'off' ||
          normalized == 'completed' ||
          normalized == 'closed') {
        return false;
      }
    }

    if (profile == null) return null;

    final profileStatus =
        _readString(profile, const ['TodayStatus', 'today_status'])?.toLowerCase();
    if (profileStatus == 'live') return true;
    if (profileStatus == 'out' ||
        profileStatus == 'completed' ||
        profileStatus == 'closed') {
      return false;
    }

    return _resolvePunchedInLegacy(profile);
  }

  static String? _statusLabelFromDuty(bool? isPunchedIn) {
    if (isPunchedIn == null) return null;
    return isPunchedIn ? 'Live' : 'Out';
  }

  static DateTime? _punchInTimeFromLastLiveSession(
    List<Map<String, dynamic>> sessions,
  ) {
    if (sessions.isEmpty) return null;
    final last = sessions.last;
    if (_resolveFromLastSession([last]) == true) {
      return _readDateTime(last, const ['PunchInTime', 'punch_in_time']);
    }
    return null;
  }

  static bool? _resolvePunchedInLegacy(Map<String, dynamic>? record) {
    if (record == null) return null;

    final boolValue = _readBool(record, const [
      'is_punched_in',
      'isPunchedIn',
      'punched_in',
      'is_in',
      'is_on_duty',
      'on_duty',
      'is_active',
      'IsActive',
    ]);
    if (boolValue != null) return boolValue;

    final status = _readString(record, const [
      'attendance_status',
      'AttendanceStatus',
      'punch_status',
      'PunchStatus',
      'duty_status',
      'DutyStatus',
      'status',
      'Status',
      'current_status',
      'CurrentStatus',
    ])?.toLowerCase();

    if (status != null) {
      if (status == 'in' ||
          status == 'punch in' ||
          status == 'punch_in' ||
          status == 'punched in' ||
          status == 'on duty' ||
          status == 'on_duty' ||
          status == 'active' ||
          status == 'live' ||
          status == '1') {
        return true;
      }
      if (status == 'out' ||
          status == 'punch out' ||
          status == 'punch_out' ||
          status == 'punched out' ||
          status == 'off duty' ||
          status == 'off_duty' ||
          status == 'inactive' ||
          status == 'completed' ||
          status == '0') {
        return false;
      }
    }

    final punchOutTime = _readString(record, const [
      'punch_out_time',
      'PunchOutTime',
      'out_time',
      'OutTime',
      'LastPunchOut',
      'last_punch_out',
    ]);
    final punchInTime = _readDateTime(record, const [
      'CurrentPunchInTime',
      'PunchInTime',
      'FirstPunchIn',
    ]);
    if (punchInTime != null && (punchOutTime == null || punchOutTime.isEmpty)) {
      return true;
    }
    if (punchOutTime != null && punchOutTime.isNotEmpty) {
      return false;
    }

    return null;
  }

  static DateTime? punchInTimeFrom(Map<String, dynamic>? record) {
    return _readDateTime(record, const [
      'CurrentPunchInTime',
      'current_punch_in_time',
      'punch_in_time',
      'PunchInTime',
      'punch_in_date_time',
      'PunchInDateTime',
      'punchin_time',
      'in_time',
      'InTime',
      'check_in_time',
      'CheckInTime',
      'start_time',
      'StartTime',
      'FirstPunchIn',
      'first_punch_in',
    ]);
  }

  static String? _readString(
    Map<String, dynamic>? source,
    List<String> keys,
  ) {
    if (source == null) return null;
    for (final key in keys) {
      final value = source[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  static bool? _readBool(
    Map<String, dynamic>? source,
    List<String> keys,
  ) {
    final value = _readString(source, keys);
    if (value == null) return null;
    return _parseBool(value);
  }

  static bool? _parseBool(dynamic value) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is num) return value == 1;
    final text = value.toString().toLowerCase().trim();
    if (text == 'true' || text == 'success' || text == '1' || text == 'yes' || text == 'in') {
      return true;
    }
    if (text == 'false' || text == 'fail' || text == '0' || text == 'no' || text == 'out') {
      return false;
    }
    return null;
  }

  static DateTime? _readDateTime(
    Map<String, dynamic>? source,
    List<String> keys,
  ) {
    final raw = _readString(source, keys);
    if (raw == null) return null;

    final msDate = _parseMsJsonDate(raw);
    if (msDate != null) return msDate.toLocal();

    final direct = DateTime.tryParse(raw);
    if (direct != null) return direct.toLocal();

    const patterns = [
      'yyyy-MM-dd HH:mm:ss',
      'yyyy-MM-ddTHH:mm:ss',
      'dd/MM/yyyy HH:mm:ss',
      'dd-MM-yyyy HH:mm:ss',
      'dd/MM/yyyy hh:mm a',
      'dd-MM-yyyy hh:mm a',
      'yyyy-MM-dd',
      'dd/MM/yyyy',
      'dd-MM-yyyy',
    ];

    for (final pattern in patterns) {
      try {
        return DateFormat(pattern).parseLoose(raw);
      } catch (_) {
        // Try next pattern.
      }
    }

    return null;
  }

  static DateTime? _parseMsJsonDate(String raw) {
    final match = RegExp(r'/Date\((-?\d+)\)/').firstMatch(raw);
    if (match == null) return null;
    final ms = int.tryParse(match.group(1)!);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }
}
