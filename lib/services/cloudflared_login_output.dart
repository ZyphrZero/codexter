import 'dart:convert';

import '../utils/rolling_buffer.dart';

/// cloudflared 自己负责打开浏览器；这里只收集日志并提供手动授权链接。
class CloudflaredLoginOutput {
  CloudflaredLoginOutput({this.onLoginUrl});

  final void Function(String)? onLoginUrl;
  final RollingBuffer _output = RollingBuffer(32000);
  bool _reportedUrl = false;

  Future<String> collect(Stream<List<int>> stdout, Stream<List<int>> stderr) async {
    await Future.wait([_read(stdout), _read(stderr)]);
    return _output.text;
  }

  Future<void> _read(Stream<List<int>> stream) async {
    // 按流分别解码、拼接完整行；不能把一次管道分片当作完整 URL。
    await for (final line
        in stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())) {
      _output.append('$line\n');
      if (_reportedUrl) continue;
      final url = parseLoginUrl(line);
      if (url == null) continue;
      _reportedUrl = true;
      onLoginUrl?.call(url);
    }
  }

  static String? parseLoginUrl(String line) {
    try {
      final text = line.trim();
      final uri = Uri.tryParse(text);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'dash.cloudflare.com' ||
          uri.path != '/argotunnel' ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          uri.port != 443 ||
          !uri.queryParameters.containsKey('aud')) {
        return null;
      }
      final callbacks = uri.queryParametersAll['callback'];
      if (callbacks == null || callbacks.length != 1) return null;
      final callback = Uri.tryParse(callbacks.single);
      if (callback == null ||
          callback.scheme != 'https' ||
          callback.host != 'login.cloudflareaccess.org' ||
          callback.userInfo.isNotEmpty ||
          callback.port != 443 ||
          callback.path.length <= 1 ||
          callback.hasQuery ||
          callback.hasFragment) {
        return null;
      }
      return text;
    } on FormatException {
      return null;
    }
  }
}
