import 'dart:io';

/// 应用内 HTTP 请求与新启动子进程共用的代理配置。
class NetworkProxy {
  NetworkProxy._();

  static String? _proxy;
  static const _loopbackBypass = 'localhost,127.0.0.1,::1';

  static String normalizeUrl(String value, {required bool enabled}) {
    final text = value.trim();
    if (text.isEmpty) {
      if (enabled) throw const FormatException('启用代理时请填写 HTTP 代理地址');
      return '';
    }
    final uri = Uri.tryParse(text);
    if (uri != null && uri.userInfo.isNotEmpty) {
      throw const FormatException('暂不支持带用户名或密码的代理地址');
    }
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.host.isEmpty ||
        !RegExp(
          r'^http://(?:\[[^\]]+\]|[^/:?#@\s]+):[0-9]+/?$',
          caseSensitive: false,
        ).hasMatch(text) ||
        !RegExp(r'^[a-zA-Z0-9._:\[\]-]+$').hasMatch(uri.host) ||
        uri.port < 1 ||
        uri.port > 65535 ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment ||
        RegExp(r'\s').hasMatch(text)) {
      throw const FormatException('代理地址须为 http://主机:端口，例如 http://127.0.0.1:7890');
    }
    final normalized = uri.replace(path: '').toString();
    // Uri 会省略 HTTP 默认端口；子进程和 Dart 的代理解析需要显式端口。
    return uri.hasPort ? normalized : '$normalized:80';
  }

  static void configure({required bool enabled, required String url}) {
    final normalized = normalizeUrl(url, enabled: enabled);
    _proxy = enabled ? normalized : null;
  }

  static HttpClient createHttpClient() => HttpClient()..findProxy = findProxy;

  // 每次请求读取当前配置，让已创建的 HTTP 客户端也能使用新设置。
  static String findProxy(Uri uri) {
    final host = uri.host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        InternetAddress.tryParse(host)?.isLoopback == true) {
      return 'DIRECT';
    }
    if (_proxy == null) return HttpClient.findProxyFromEnvironment(uri);
    return HttpClient.findProxyFromEnvironment(uri, environment: processEnvironment());
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
      for (final key in ['http_proxy', 'https_proxy', 'all_proxy']) {
        environment[key] = proxy;
        environment[key.toUpperCase()] = proxy;
      }
      environment['no_proxy'] = bypass;
      environment['NO_PROXY'] = bypass;
    }
    environment.addAll(overrides);
    // Unix 环境变量区分大小写；显式同时提供两种拼写时，小写优先，
    // 不让 JSON 字段顺序决定路由，并保证只读大写变量的工具得到相同值。
    for (final key in ['http_proxy', 'https_proxy', 'all_proxy', 'no_proxy']) {
      final value = overrides[key] ?? overrides[key.toUpperCase()];
      if (value == null) continue;
      environment[key] = value;
      environment[key.toUpperCase()] = value;
    }
    return environment;
  }
}
