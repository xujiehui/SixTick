import 'dart:convert';
import 'dart:io';

class ApiException implements Exception {
  final String code;
  final int status;
  const ApiException(this.code, this.status);
  @override
  String toString() => code;
}

class Api {
  final Uri base;
  final String? token;
  Api(String url, {this.token}) : base = Uri.parse(url) {
    const development = bool.fromEnvironment('ALLOW_INSECURE_LOCALHOST');
    final loopback = [
      'localhost',
      '127.0.0.1',
      '::1',
      '10.0.2.2',
    ].contains(base.host);
    if (base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        base.path != '' && base.path != '/' ||
        base.scheme != 'https' &&
            !(development && loopback && base.scheme == 'http')) {
      throw const FormatException('https_required');
    }
  }
  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.openUrl(method, base.resolve(path));
      request.followRedirects =
          false; // Never forward bearer credentials across redirects.
      request.headers.contentType = ContentType.json;
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.contentLength = bytes.length;
        request.add(bytes);
      } else {
        request.contentLength = 0;
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.addAll(chunk);
        if (bytes.length > 32 * 1024 * 1024) {
          throw const FormatException('file_too_large');
        }
      }
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          data['error'] as String? ?? 'server_error',
          response.statusCode,
        );
      }
      return data;
    } finally {
      client.close(force: true);
    }
  }
}
