class ApiConfig {
  static const baseUrl =
      'https://heaven.sofratechnology.com/webservice.asmx';

  static const apiUserName = 'heaven';
  static const apiPassword = 'hb@2024';
  static const namespace = 'http://tempuri.org/';

  static const connectTimeout = Duration(seconds: 30);
  static const idleTimeout = Duration(seconds: 60);
  static const requestTimeout = Duration(seconds: 90);
}
