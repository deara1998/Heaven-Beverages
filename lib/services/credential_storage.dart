import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StoredCredentials {
  const StoredCredentials({
    required this.mobileNo,
    required this.password,
  });

  final String mobileNo;
  final String password;
}

class CredentialStorage {
  CredentialStorage({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
                resetOnError: true,
              ),
            );

  static const _mobileKey = 'login_mobile_no';
  static const _passwordKey = 'login_password';

  final FlutterSecureStorage _secureStorage;

  Future<void> save({
    required String mobileNo,
    required String password,
  }) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_mobileKey, mobileNo);
      await prefs.setString(_passwordKey, password);
      return;
    }

    await _secureStorage.write(key: _mobileKey, value: mobileNo);
    await _secureStorage.write(key: _passwordKey, value: password);
  }

  Future<StoredCredentials?> load() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final mobile = prefs.getString(_mobileKey);
      final password = prefs.getString(_passwordKey);
      if (mobile == null || password == null) return null;
      return StoredCredentials(mobileNo: mobile, password: password);
    }

    try {
      final mobile = await _secureStorage
          .read(key: _mobileKey)
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
      final password = await _secureStorage
          .read(key: _passwordKey)
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
      if (mobile == null || password == null) return null;
      return StoredCredentials(mobileNo: mobile, password: password);
    } catch (error) {
      debugPrint('[Credentials] Secure storage read failed: $error');
      return null;
    }
  }

  Future<void> clear() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_mobileKey);
      await prefs.remove(_passwordKey);
      return;
    }

    await _secureStorage.delete(key: _mobileKey);
    await _secureStorage.delete(key: _passwordKey);
  }
}
