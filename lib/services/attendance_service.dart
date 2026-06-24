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
    this.isPunchedIn,
    this.punchInTime,
    this.data,
    this.record,
  });

  factory StaffDashboardResult.fromJson(Map<String, dynamic> json, String raw) {
    final record = _extractRecord(json);
    final punchInTime = _readDateTime(record, const [
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
    ]);

    return StaffDashboardResult(
      raw: raw,
      success: _parseBool(
        json['success'] ?? json['Success'] ?? json['status'] ?? json['Status'],
      ),
      message: _readString(json, const ['message', 'Message', 'msg', 'Msg']),
      isPunchedIn: _resolvePunchedIn(record, json),
      punchInTime: punchInTime,
      data: json,
      record: record,
    );
  }

  final String raw;
  final bool? success;
  final String? message;
  final bool? isPunchedIn;
  final DateTime? punchInTime;
  final Map<String, dynamic>? data;
  final Map<String, dynamic>? record;

  bool get isSuccess {
    if (success != null) return success!;
    final lower = raw.toLowerCase();
    return lower.contains('"success":"1"') ||
        lower.contains('"success":1') ||
        lower.contains('"success":true') ||
        lower.contains('"status":"success"') ||
        lower.contains('"status":1');
  }

  static Map<String, dynamic>? _extractRecord(Map<String, dynamic> json) {
    final result = json['result'] ?? json['Result'] ?? json['data'] ?? json['Data'];
    if (result is List && result.isNotEmpty) {
      final first = result.first;
      if (first is Map<String, dynamic>) return first;
      if (first is Map) return Map<String, dynamic>.from(first);
    }
    if (result is Map<String, dynamic>) return result;
    if (result is Map) return Map<String, dynamic>.from(result);
    return json;
  }

  static bool? _resolvePunchedIn(
    Map<String, dynamic>? record,
    Map<String, dynamic> json,
  ) {
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

    final boolFromRoot = _readBool(json, const [
      'is_punched_in',
      'isPunchedIn',
      'punched_in',
      'is_in',
      'is_on_duty',
      'on_duty',
    ]);
    if (boolFromRoot != null) return boolFromRoot;

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
          status == '0') {
        return false;
      }
    }

    final punchOutTime = _readString(record, const [
      'punch_out_time',
      'PunchOutTime',
      'out_time',
      'OutTime',
    ]);
    if (StaffDashboardResult.punchInTimeFrom(record) != null &&
        (punchOutTime == null || punchOutTime.isEmpty)) {
      return true;
    }
    if (punchOutTime != null && punchOutTime.isNotEmpty) {
      return false;
    }

    return null;
  }

  static DateTime? punchInTimeFrom(Map<String, dynamic>? record) {
    return _readDateTime(record, const [
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

    final direct = DateTime.tryParse(raw);
    if (direct != null) return direct;

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
}
