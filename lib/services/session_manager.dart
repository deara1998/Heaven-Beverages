import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:heaven_beverages/models/user_session.dart';
import 'package:heaven_beverages/services/auth_service.dart';
import 'package:heaven_beverages/services/credential_storage.dart';
import 'package:heaven_beverages/services/session_storage.dart';

enum SilentLoginStatus { success, noCredentials, failed }

class SilentLoginResult {
  const SilentLoginResult._({
    required this.status,
    this.session,
    this.message,
  });

  const SilentLoginResult.success(UserSession session)
      : this._(status: SilentLoginStatus.success, session: session);

  const SilentLoginResult.noCredentials()
      : this._(status: SilentLoginStatus.noCredentials);

  const SilentLoginResult.failed([String? message])
      : this._(status: SilentLoginStatus.failed, message: message);

  final SilentLoginStatus status;
  final UserSession? session;
  final String? message;

  bool get isSuccess => status == SilentLoginStatus.success;
}

class SessionManager {
  SessionManager({
    AuthService? authService,
    SessionStorage? sessionStorage,
    CredentialStorage? credentialStorage,
  })  : _authService = authService ?? AuthService(),
        _sessionStorage = sessionStorage ?? SessionStorage(),
        _credentialStorage = credentialStorage ?? CredentialStorage();

  final AuthService _authService;
  final SessionStorage _sessionStorage;
  final CredentialStorage _credentialStorage;

  /// Calls login API silently and refreshes the stored session.
  Future<SilentLoginResult> refreshSessionSilently() async {
    try {
      return await _refreshSessionSilently().timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          debugPrint('[Session] Silent login timed out');
          return const SilentLoginResult.failed('Connection timed out');
        },
      );
    } catch (error) {
      debugPrint('[Session] Silent login unexpected error: $error');
      return SilentLoginResult.failed(error.toString());
    }
  }

  Future<SilentLoginResult> _refreshSessionSilently() async {
    final credentials = await _credentialStorage.load();
    if (credentials == null) {
      return const SilentLoginResult.noCredentials();
    }

    try {
      final deviceId = await _sessionStorage.loadOrCreateDeviceId();
      final result = await _authService.login(
        mobileNo: credentials.mobileNo,
        password: credentials.password,
        deviceId: deviceId,
      );

      if (!result.isSuccess) {
        debugPrint('[Session] Silent login failed: ${result.message ?? result.raw}');
        return SilentLoginResult.failed(result.message);
      }

      final session = UserSession.fromLogin(
        result,
        mobileNo: credentials.mobileNo,
      );
      await _sessionStorage.saveUserSession(
        session,
        loginResponseRaw: result.raw,
      );
      debugPrint('[Session] Silent login success for ${session.displayName}');
      return SilentLoginResult.success(session);
    } on UserSessionException catch (error) {
      return SilentLoginResult.failed(error.message);
    } on AuthException catch (error) {
      return SilentLoginResult.failed(error.message);
    } catch (error) {
      debugPrint('[Session] Silent login error: $error');
      return SilentLoginResult.failed(error.toString());
    }
  }

  Future<void> saveLoginCredentials({
    required String mobileNo,
    required String password,
    required UserSession session,
    String? loginResponseRaw,
  }) async {
    await _credentialStorage.save(mobileNo: mobileNo, password: password);
    await _sessionStorage.saveUserSession(
      session,
      loginResponseRaw: loginResponseRaw,
    );
  }

  Future<void> clearSession() async {
    await _credentialStorage.clear();
    await _sessionStorage.clearUserSession();
  }

  void dispose() {
    _authService.dispose();
  }
}
