class SoapUtils {
  static String escapeXml(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static String buildEnvelope({
    required String namespace,
    required String apiUserName,
    required String apiPassword,
    required String body,
  }) {
    return '''<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Header>
    <AuthUser xmlns="$namespace">
      <UserName>${escapeXml(apiUserName)}</UserName>
      <Password>${escapeXml(apiPassword)}</Password>
    </AuthUser>
  </soap:Header>
  <soap:Body>
    $body
  </soap:Body>
</soap:Envelope>''';
  }
}
