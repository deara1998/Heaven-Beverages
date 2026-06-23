import 'dart:convert';

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
