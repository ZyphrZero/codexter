import 'dart:convert';
import 'dart:io';

import 'tunnel_service.dart';

/// 共享的创建/复用决策；命令和凭据回调可注入，不依赖真实账户进行测试。
class CloudflaredTunnelSetup {
  CloudflaredTunnelSetup({
    required this.run,
    required this.adoptCreatedCredentials,
    required this.hasExistingCredentials,
  });

  final Future<CloudflaredCommandResult> Function(List<String>) run;
  final Future<bool> Function(String) adoptCreatedCredentials;
  final Future<bool> Function(String) hasExistingCredentials;
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  Future<String> create(String name, String pendingPath) async {
    if (name.trim().isEmpty) throw const FormatException('Tunnel 名称不能为空');
    late CloudflaredCommandResult result;
    try {
      result = await run(['create', '--output', 'json', '--credentials-file', pendingPath, name]);
    } on CloudflaredCommandException catch (error) {
      // 只针对重名复用。权限、网络等错误不能被另一次查询覆盖。
      if (!error.output.toLowerCase().contains('tunnel with name already exists')) rethrow;
      return _reuse(name);
    }

    final created = _decode(result.stdout);
    final id = _matchingId(created, name);
    if (id == null) throw const FormatException('创建结果中缺少匹配的 Tunnel 名称或有效 ID');
    if (!await adoptCreatedCredentials(id)) {
      throw Exception('Tunnel「$name」已创建（$id），但本机未取得有效的运行凭据，请检查凭据文件后重试。');
    }
    return id;
  }

  Future<String> _reuse(String name) async {
    final result = await run(['list', '--output', 'json', '--name', name]);
    final decoded = _decode(result.stdout);
    if (decoded is! List) throw const FormatException('Tunnel 列表不是有效的 JSON 数组');
    final ids = decoded.map((item) => _matchingId(item, name)).whereType<String>().toSet();
    if (ids.length != 1) {
      throw Exception('Tunnel 名称「$name」已存在，但未能唯一确认其 ID；请换一个名称，或在 Cloudflare 核对现有 Tunnel。');
    }
    final id = ids.single;
    if (!await hasExistingCredentials(id)) {
      throw Exception(
        'Tunnel「$name」已存在（$id），但这台电脑缺少有效的 $id.json 运行凭据。'
        '请为这台电脑换一个 Tunnel 名称和独立测试域名，或从原电脑安全导入对应凭据。'
        '重新登录只获取 cert.pem，不会重新生成已有 Tunnel 的运行凭据。',
      );
    }
    return id;
  }

  static Object? _decode(String output) {
    try {
      return jsonDecode(output);
    } on FormatException {
      // create --output json 可包含 token，不能把原始响应附在解析异常中。
      throw const FormatException('cloudflared 返回了无法解析的 Tunnel JSON');
    }
  }

  static String? _matchingId(Object? item, String name) {
    if (item is! Map || item['name'] != name) return null;
    final deleted = item['deleted_at'];
    // Go 的 time.Time 零值也会被序列化；未删除的条目常见此值。
    if (deleted != null && deleted != '' && deleted != '0001-01-01T00:00:00Z') return null;
    final id = item['id'];
    return id is String && _uuid.hasMatch(id) ? id.toLowerCase() : null;
  }

  /// 只校验必需字段与 Tunnel ID，不在异常或日志中泄露 TunnelSecret。
  static Future<bool> credentialsMatch(File file, String tunnelId) async {
    try {
      if (!await file.exists()) return false;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map ||
          data['TunnelID'] is! String ||
          (data['TunnelID'] as String).toLowerCase() != tunnelId.toLowerCase() ||
          data['AccountTag'] is! String ||
          (data['AccountTag'] as String).trim().isEmpty ||
          data['TunnelSecret'] is! String) {
        return false;
      }
      return base64.decode(data['TunnelSecret'] as String).length >= 32;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }
}
