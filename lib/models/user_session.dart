import 'package:heaven_beverages/services/auth_service.dart';

class UserSession {
  const UserSession({
    required this.userId,
    required this.mobileNo,
    this.name,
    this.rawData,
  });

  factory UserSession.fromLogin(LoginResult result, {required String mobileNo}) {
    final userRecord = LoginResult.extractUserRecord(result.data);
    final userId = resolveUserId(result, userRecord);

    if (userId == null || userId.isEmpty) {
      throw UserSessionException(
        'Login response did not include UserId. Cannot continue.',
      );
    }

    final name = resolveName(result, userRecord);
    final storedMobile = resolveMobile(result, userRecord) ?? mobileNo;

    return UserSession(
      userId: userId,
      mobileNo: storedMobile,
      name: name,
      rawData: userRecord ?? result.data,
    );
  }

  static String? resolveUserId(
    LoginResult result, [
    Map<String, dynamic>? userRecord,
  ]) {
    final record = userRecord ?? LoginResult.extractUserRecord(result.data);
    return LoginResult.readField(record, const [
      'UserId',
      'user_id',
      'userId',
      'User_ID',
      'id',
      'employee_id',
    ]) ??
        result.userId;
  }

  static String? resolveName(
    LoginResult result, [
    Map<String, dynamic>? userRecord,
  ]) {
    final record = userRecord ?? LoginResult.extractUserRecord(result.data);
    return LoginResult.readField(record, const [
      'FullName',
      'full_name',
      'name',
      'user_name',
      'employee_name',
    ]) ??
        result.name;
  }

  static String? resolveMobile(
    LoginResult result, [
    Map<String, dynamic>? userRecord,
  ]) {
    final record = userRecord ?? LoginResult.extractUserRecord(result.data);
    return LoginResult.readField(record, const [
      'MobileNo',
      'mobile_no',
      'mobileNo',
      'Mobile',
    ]) ??
        result.mobileNo;
  }

  factory UserSession.fromJson(Map<String, dynamic> json) {
    return UserSession(
      userId: json['userId'] as String,
      mobileNo: json['mobileNo'] as String,
      name: json['name'] as String?,
    );
  }

  final String userId;
  final String mobileNo;
  final String? name;
  final Map<String, dynamic>? rawData;

  String get displayName => name?.trim().isNotEmpty == true ? name! : mobileNo;

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'mobileNo': mobileNo,
        'name': name,
      };
}

class UserSessionException implements Exception {
  UserSessionException(this.message);

  final String message;

  @override
  String toString() => message;
}
