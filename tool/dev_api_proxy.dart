import 'dart:io';

const _targetHost = 'heaven.sofratechnology.com';
const _targetPath = '/webservice.asmx';
const _proxyPort = 8888;

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, _proxyPort);
  // ignore: avoid_print
  print(
    'Dev API proxy running at http://localhost:$_proxyPort$_targetPath\n'
    'Forwarding to https://$_targetHost$_targetPath',
  );

  await for (final request in server) {
    if (request.method == 'OPTIONS') {
      _setCorsHeaders(request.response);
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      continue;
    }

    if (request.method != 'POST' || request.uri.path != _targetPath) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      continue;
    }

    try {
      final bodyBytes = await request.fold<List<int>>(
        <int>[],
        (previous, element) => previous..addAll(element),
      );

      final client = HttpClient();
      final proxyRequest = await client.post(_targetHost, 443, _targetPath);

      final contentType = request.headers.value('content-type');
      if (contentType != null) {
        proxyRequest.headers.set('Content-Type', contentType);
      }

      final soapAction = request.headers.value('soapaction');
      if (soapAction != null) {
        proxyRequest.headers.set('SOAPAction', soapAction);
      }

      proxyRequest.add(bodyBytes);
      final proxyResponse = await proxyRequest.close();

      _setCorsHeaders(request.response);
      request.response.statusCode = proxyResponse.statusCode;
      await proxyResponse.pipe(request.response);
    } catch (error) {
      _setCorsHeaders(request.response);
      request.response.statusCode = HttpStatus.badGateway;
      request.response.write('Proxy error: $error');
      await request.response.close();
    }
  }
}

void _setCorsHeaders(HttpResponse response) {
  response.headers.set('Access-Control-Allow-Origin', '*');
  response.headers.set('Access-Control-Allow-Methods', 'POST, OPTIONS');
  response.headers.set(
    'Access-Control-Allow-Headers',
    'Content-Type, SOAPAction',
  );
}
