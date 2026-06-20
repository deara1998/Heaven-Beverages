import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:heaven_beverages/services/api_config.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

class ApiClient {
  factory ApiClient() => _instance;

  ApiClient._internal() : _client = _createClient();

  static final ApiClient _instance = ApiClient._internal();

  final http.Client _client;

  static http.Client _createClient() {
    if (kIsWeb) {
      return http.Client();
    }

    final httpClient = HttpClient()
      ..connectionTimeout = ApiConfig.connectTimeout
      ..idleTimeout = ApiConfig.idleTimeout
      ..autoUncompress = true;

    return IOClient(httpClient);
  }

  static Map<String, String> soapHeaders(String operation) {
    return {
      'Content-Type': 'text/xml; charset=utf-8',
      'SOAPAction': '"${ApiConfig.namespace}$operation"',
      'Accept': 'text/xml',
      'Connection': 'Keep-Alive',
    };
  }

  Future<http.Response> post({
    required String operation,
    required Uri url,
    required Map<String, String> headers,
    required String body,
  }) async {
    _debugLog('[$operation] REQUEST');
    _debugLog('URL: $url');
    _debugLog('Headers: $headers');
    _debugLog('Body:\n$body');

    try {
      final response = await _client
          .post(url, headers: headers, body: body)
          .timeout(
            ApiConfig.requestTimeout,
            onTimeout: () {
              throw ApiTimeoutException(
                '$operation timed out after '
                '${ApiConfig.requestTimeout.inSeconds} seconds.',
              );
            },
          );

      _debugLog('[$operation] RESPONSE');
      _debugLog('Status: ${response.statusCode}');
      _debugLog('Headers: ${response.headers}');
      _debugLog('Body:\n${response.body}');

      return response;
    } on ApiTimeoutException {
      rethrow;
    } on SocketException catch (error) {
      _debugLog('[$operation] NETWORK ERROR: $error');
      throw ApiNetworkException(
        'Network error while calling $operation. Check internet connection.',
      );
    } on HttpException catch (error) {
      _debugLog('[$operation] HTTP ERROR: $error');
      throw ApiNetworkException(
        'HTTP error while calling $operation: ${error.message}',
      );
    } catch (error, stackTrace) {
      _debugLog('[$operation] ERROR: $error');
      _debugLog('[$operation] Stack trace:\n$stackTrace');
      rethrow;
    }
  }

  void _debugLog(String message) {
    if (kDebugMode) {
      debugPrint('[API] $message');
    }
  }

  void dispose() {
    // Shared client is reused across the app.
  }
}

class ApiTimeoutException implements Exception {
  ApiTimeoutException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ApiNetworkException implements Exception {
  ApiNetworkException(this.message);

  final String message;

  @override
  String toString() => message;
}
