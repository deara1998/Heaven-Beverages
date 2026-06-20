import 'dart:convert';

import 'package:xml/xml.dart';

import 'api_client.dart';
import 'api_config.dart';
import 'soap_utils.dart';

class AuthService {
  AuthService({ApiClient? apiClient}) : _apiClient = apiClient ?? ApiClient();

  final ApiClient _apiClient;

  Future<LoginResult> login({
    required String mobileNo,
    required String password,
    required String deviceId,
    String lang = 'en',
  }) async {
    final envelope = _buildLoginEnvelope(
      mobileNo: mobileNo,
      password: password,
      deviceId: deviceId,
      lang: lang,
    );

    final response = await _apiClient.post(
      operation: 'login',
      url: Uri.parse(ApiConfig.baseUrl),
      headers: ApiClient.soapHeaders('login'),
      body: envelope,
    );

    if (response.statusCode != 200) {
      throw AuthException(
        'Login failed with status ${response.statusCode}',
      );
    }

    return _parseLoginResponse(response.body);
  }

  String _buildLoginEnvelope({
    required String mobileNo,
    required String password,
    required String deviceId,
    required String lang,
  }) {
    return SoapUtils.buildEnvelope(
      namespace: ApiConfig.namespace,
      apiUserName: ApiConfig.apiUserName,
      apiPassword: ApiConfig.apiPassword,
      body: '''
    <login xmlns="${ApiConfig.namespace}">
      <mobile_no>${SoapUtils.escapeXml(mobileNo)}</mobile_no>
      <password>${SoapUtils.escapeXml(password)}</password>
      <device_id>${SoapUtils.escapeXml(deviceId)}</device_id>
      <lang>${SoapUtils.escapeXml(lang)}</lang>
    </login>''',
    );
  }

  LoginResult _parseLoginResponse(String body) {
    final document = XmlDocument.parse(body);
    final loginResultElement = document
        .findAllElements('loginResult')
        .firstOrNull;

    if (loginResultElement == null) {
      throw AuthException('Invalid response from server');
    }

    final rawResult = loginResultElement.innerText.trim();
    if (rawResult.isEmpty) {
      throw AuthException('Empty response from server');
    }

    try {
      final decoded = jsonDecode(rawResult);
      if (decoded is Map<String, dynamic>) {
        return LoginResult.fromJson(decoded, rawResult);
      }
    } on FormatException {
      // Response may be plain text instead of JSON.
    }

    return LoginResult(raw: rawResult);
  }

  void dispose() {
    _apiClient.dispose();
  }
}

class LoginResult {
  const LoginResult({
    required this.raw,
    this.success,
    this.message,
    this.userId,
    this.name,
    this.mobileNo,
    this.userRecord,
    this.data,
  });

  factory LoginResult.fromJson(Map<String, dynamic> json, String raw) {
    final successValue = json['success'] ??
        json['Success'] ??
        json['status'] ??
        json['Status'];

    final messageValue =
        json['message'] ?? json['Message'] ?? json['msg'] ?? json['Msg'];

    final userRecord = extractUserRecord(json);

    return LoginResult(
      raw: raw,
      success: _parseBool(successValue),
      message: messageValue?.toString(),
      userId: readField(userRecord, const [
        'UserId',
        'user_id',
        'userId',
        'User_ID',
        'id',
        'employee_id',
      ]),
      name: readField(userRecord, const [
        'FullName',
        'full_name',
        'name',
        'user_name',
        'employee_name',
      ]),
      mobileNo: readField(userRecord, const [
        'MobileNo',
        'mobile_no',
        'mobileNo',
        'Mobile',
      ]),
      userRecord: userRecord,
      data: json,
    );
  }

  final String raw;
  final bool? success;
  final String? message;
  final String? userId;
  final String? name;
  final String? mobileNo;
  final Map<String, dynamic>? userRecord;
  final Map<String, dynamic>? data;

  static Map<String, dynamic>? extractUserRecord(Map<String, dynamic>? json) {
    if (json == null) return null;

    final result = json['result'] ?? json['Result'];
    if (result is List && result.isNotEmpty) {
      final first = result.first;
      if (first is Map<String, dynamic>) return first;
      if (first is Map) return Map<String, dynamic>.from(first);
    }
    if (result is Map<String, dynamic>) return result;
    if (result is Map) return Map<String, dynamic>.from(result);

    return json;
  }

  static String? readField(
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

  bool get isSuccess {
    if (success == true) return true;

    final response = data;
    if (response != null) {
      final successValue = response['success'] ??
          response['Success'] ??
          response['status'] ??
          response['Status'];
      if (successValue == 1 ||
          successValue == '1' ||
          successValue == true ||
          successValue == 'true') {
        return true;
      }
    }

    final lower = raw.toLowerCase();
    return lower.contains('"success":"1"') ||
        lower.contains('"success":1') ||
        lower.contains('"success": 1') ||
        lower.contains('"success":true') ||
        lower.contains('"success": true') ||
        lower.contains('"status":"success"') ||
        lower.contains('"status":1') ||
        lower.contains('"status": 1');
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

class AuthException implements Exception {
  AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
