import 'dart:io';

import 'package:socks5_proxy/socks_client.dart';

/// Codexter 应用内 HTTP 请求与新启动子进程共用的出站代理。
///
/// HTTP 代理交给 Dart HttpClient 的 CONNECT 实现；SOCKS5 使用自定义连接工厂，
/// 因此下载、Cloudflare API、DoH、HTTP MCP 等应用请求都能实际经过 SOCKS5。
class NetworkProxy {
  NetworkProxy._();

  static Uri? _proxy;
  static String? _resolvedSocksHost;
  static InternetAddress? _resolvedSocksAddress;
  static const _loopbackBypass = 'localhost,127.0.0.1,::1';
  static const _probeUrl = 'https://api.cloudflare.com/client/v4/ips';

  static Uri? get configuredProxy => _proxy;

  static String normalizeUrl(String value, {required bool enabled}) {
    final text = value.trim();
    if (text.isEmpty) {
      if (enabled) throw const FormatException('启用代理时请填写代理服务器地址');
      return '';
    }
    // 关闭自定义代理时保留用户输入，但不让历史无效值阻塞应用启动或向导。
    if (!enabled) return text;

    final uri = Uri.tryParse(text);
    final scheme = uri?.scheme.toLowerCase();
    if (uri == null ||
        (scheme != 'http' && scheme != 'socks5') ||
        uri.host.isEmpty ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment ||
        RegExp(r'\s').hasMatch(text)) {
      throw const FormatException('代理地址须为 http://主机:端口 或 socks5://主机:端口，例如 http://127.0.0.1:7890');
    }

    return Uri(scheme: scheme, host: uri.host, port: uri.port).toString();
  }

  static void configure({required bool enabled, required String url}) {
    final normalized = normalizeUrl(url, enabled: enabled);
    final proxy = enabled ? Uri.parse(normalized) : null;
    if (_proxy?.host != proxy?.host || _proxy?.scheme != proxy?.scheme) {
      _resolvedSocksHost = null;
      _resolvedSocksAddress = null;
    }
    _proxy = proxy;
  }

  static HttpClient createHttpClient() => _createHttpClient(_proxy);

  /// 通过尚未保存的代理配置做真实 HTTPS 连通测试。
  static Future<void> testConnection(String url) async {
    final normalized = normalizeUrl(url, enabled: true);
    final proxy = Uri.parse(normalized);
    final client = _createHttpClient(proxy)
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse(_probeUrl));
      final response = await request.close().timeout(const Duration(seconds: 10));
      await response.drain<void>();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('代理已连接，但 Cloudflare 探测返回 HTTP ${response.statusCode}');
      }
    } finally {
      client.close(force: true);
    }
  }

  static HttpClient _createHttpClient(Uri? proxy) {
    final client = HttpClient();
    if (proxy == null) {
      client.findProxy = (uri) =>
          _isLoopback(uri.host) ? 'DIRECT' : HttpClient.findProxyFromEnvironment(uri);
      return client;
    }

    if (proxy.scheme == 'http') {
      client.findProxy = (uri) =>
          _isLoopback(uri.host) ? 'DIRECT' : 'PROXY ${proxy.host}:${proxy.port}';
      return client;
    }

    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, _, _) {
      if (_isLoopback(uri.host)) return _directConnectionTask(uri);
      return _socksConnectionTask(uri, proxy);
    };
    return client;
  }

  static Future<ConnectionTask<Socket>> _socksConnectionTask(Uri uri, Uri proxy) async {
    final proxyAddress = await _resolveProxyAddress(proxy.host);
    final settings = ProxySettings(proxyAddress, proxy.port);
    Socket? activeSocket;
    var cancelled = false;
    final socketFuture = Future<Socket>(() async {
      final target =
          InternetAddress.tryParse(uri.host) ??
          InternetAddress(uri.host, type: InternetAddressType.unix);
      final socket = await SocksTCPClient.connect([settings], target, _targetPort(uri));
      activeSocket = socket;
      if (cancelled) {
        socket.destroy();
        throw const SocketException('SOCKS5 connection cancelled');
      }
      if (uri.scheme == 'https') {
        final secure = await socket.secure(uri.host);
        activeSocket = secure;
        return secure;
      }
      return socket;
    });

    return ConnectionTask.fromSocket<Socket>(socketFuture, () {
      cancelled = true;
      activeSocket?.destroy();
    });
  }

  static Future<ConnectionTask<Socket>> _directConnectionTask(Uri uri) async {
    final port = _targetPort(uri);
    if (uri.scheme == 'https') {
      final task = await SecureSocket.startConnect(uri.host, port);
      return ConnectionTask.fromSocket<Socket>(task.socket, task.cancel);
    }
    return Socket.startConnect(uri.host, port);
  }

  static Future<InternetAddress> _resolveProxyAddress(String host) async {
    if (_resolvedSocksHost == host && _resolvedSocksAddress != null) {
      return _resolvedSocksAddress!;
    }
    final literal = InternetAddress.tryParse(host);
    final addresses = literal == null
        ? await InternetAddress.lookup(host).timeout(const Duration(seconds: 8))
        : <InternetAddress>[literal];
    if (addresses.isEmpty) throw SocketException('无法解析 SOCKS5 代理服务器：$host');
    final address = addresses.firstWhere(
      (item) => item.type == InternetAddressType.IPv4,
      orElse: () => addresses.first,
    );
    _resolvedSocksHost = host;
    _resolvedSocksAddress = address;
    return address;
  }

  static int _targetPort(Uri uri) {
    if (uri.hasPort) return uri.port;
    return uri.scheme == 'https' ? HttpClient.defaultHttpsPort : HttpClient.defaultHttpPort;
  }

  static bool _isLoopback(String host) {
    final normalized = host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
    return normalized == 'localhost' ||
        normalized.endsWith('.localhost') ||
        InternetAddress.tryParse(normalized)?.isLoopback == true;
  }

  /// 单个 MCP 的显式环境变量仍优先于全局默认值。
  static Map<String, String> processEnvironment({Map<String, String> overrides = const {}}) {
    final environment = Map<String, String>.of(Platform.environment);
    final proxy = _proxy;
    if (proxy != null) {
      final bypass = [
        _loopbackBypass,
        environment['no_proxy'] ?? environment['NO_PROXY'] ?? '',
      ].where((value) => value.isNotEmpty).join(',');
      final value = proxy.toString();
      for (final key in ['http_proxy', 'https_proxy', 'all_proxy']) {
        environment[key] = value;
        environment[key.toUpperCase()] = value;
      }
      environment['no_proxy'] = bypass;
      environment['NO_PROXY'] = bypass;
    }

    environment.addAll(overrides);
    for (final key in ['http_proxy', 'https_proxy', 'all_proxy', 'no_proxy']) {
      final value = overrides[key] ?? overrides[key.toUpperCase()];
      if (value == null) continue;
      environment[key] = value;
      environment[key.toUpperCase()] = value;
    }
    return environment;
  }
}
