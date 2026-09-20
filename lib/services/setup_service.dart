import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/global_config.dart';
import '../platform/desktop_platform.dart';
import '../utils/app_paths.dart';
import '../utils/path_guard.dart';
import 'cloudflared_login_output.dart';
import 'cloudflared_tunnel_setup.dart';
import 'network_proxy.dart';
import 'tunnel_service.dart';

const cloudflaredVersion = '2026.7.2';

class CloudflareLoginResult {
  final bool success;
  final bool alreadyLoggedIn;
  final String? error;

  const CloudflareLoginResult._({required this.success, this.alreadyLoggedIn = false, this.error});

  static const alreadyDone = CloudflareLoginResult._(success: true, alreadyLoggedIn: true);
  static const done = CloudflareLoginResult._(success: true);

  static CloudflareLoginResult failed(String error) {
    return CloudflareLoginResult._(success: false, error: error);
  }
}

class DownloadProgress {
  final int received;
  final int total;

  const DownloadProgress(this.received, this.total);

  double get fraction => total > 0 ? received / total : 0;
}

/// 首次配置向导使用的服务：cloudflared 安装、Cloudflare 登录、Tunnel 创建与 DNS
class SetupService {
  Future<String> get cloudflaredPath => AppPaths.cloudflaredPath;

  String normalizeDomain(String domain) {
    final text = domain.trim();
    if (text.isEmpty) return '';
    final withScheme = text.contains('://') ? text : 'https://$text';
    try {
      final host = Uri.parse(withScheme).host.toLowerCase();
      return host.replaceAll(RegExp(r'\.$'), '');
    } catch (_) {
      return text.toLowerCase();
    }
  }

  /// 统一返回绝对路径，不能把 PATH 中的命令名作为文件路径保存。
  Future<String?> findCloudflaredBin({String? configuredPath}) async {
    final executableName = Platform.isWindows ? 'cloudflared.exe' : 'cloudflared';
    final pathDirectories = (Platform.environment['PATH'] ?? '').split(
      Platform.isWindows ? ';' : ':',
    );
    final candidates = <String>[
      if (configuredPath != null && configuredPath.isNotEmpty) configuredPath,
      await cloudflaredPath,
      if (Platform.isWindows) ...[
        p.join(_homeDir(), executableName),
        r'C:\Program Files (x86)\cloudflared\cloudflared.exe',
        r'C:\Program Files\cloudflared\cloudflared.exe',
      ] else ...[
        '/usr/local/bin/cloudflared',
        '/usr/bin/cloudflared',
        '/opt/homebrew/bin/cloudflared',
      ],
      for (final directory in pathDirectories)
        if (directory.isNotEmpty)
          p.join(
            Platform.isWindows ? directory.replaceAll(RegExp(r'^"|"$'), '') : directory,
            executableName,
          ),
    ];

    for (final candidate in candidates.toSet()) {
      final file = File(candidate);
      if (await file.exists()) return p.normalize(file.absolute.path);
    }
    return null;
  }

  Future<String> probeVersion(String bin) async {
    try {
      final result = await Process.run(bin, ['--version'], stdoutEncoding: null);
      return TextDecode.bytes(result.stdout).trim();
    } catch (_) {
      return '';
    }
  }

  Future<void> downloadCloudflared({void Function(DownloadProgress)? onProgress}) async {
    final targetPath = await cloudflaredPath;
    if (await desktopPlatform.installCloudflared(
      source: Uri.parse(_downloadUrl),
      targetPath: targetPath,
      onProgress: (received, total) => onProgress?.call(DownloadProgress(received, total)),
    )) {
      return;
    }
    final client = NetworkProxy.createHttpClient()..connectionTimeout = const Duration(seconds: 30);

    try {
      final request = await client.getUrl(Uri.parse(_downloadUrl));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw Exception('下载失败 (HTTP ${response.statusCode})');
      }

      final total = response.contentLength;
      var received = 0;
      final sink = File(targetPath).openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(DownloadProgress(received, total));
      }
      await sink.close();

      if (!Platform.isWindows) {
        final chmod = await Process.run('chmod', ['+x', targetPath]);
        if (chmod.exitCode != 0) throw Exception('设置执行权限失败');
      }

      final probe = await Process.run(targetPath, ['--version']);
      if (probe.exitCode != 0) throw Exception('下载的文件无法运行');
    } catch (_) {
      final file = File(targetPath);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  /// 使用当前应用环境独立的 cert.pem 登录；[force] 用于切换 Zone 时重新授权。
  Future<CloudflareLoginResult> loginCloudflare(
    String bin, {
    bool force = false,
    void Function(String?)? onLoginUrl,
  }) async {
    onLoginUrl?.call(null);
    await migrateLegacyCloudflareCredentials();
    final certFile = File(await AppPaths.originCertPath);
    if (await certFile.exists() && !force) {
      return CloudflareLoginResult.alreadyDone;
    }

    File? backup;
    if (force && await certFile.exists()) {
      backup = File('${certFile.path}.codexter-backup');
      if (await backup.exists()) await backup.delete();
      await certFile.copy(backup.path);
      await certFile.delete();
    }

    final loginHome = Directory(await AppPaths.cloudflareLoginHome);
    if (await loginHome.exists()) await loginHome.delete(recursive: true);
    await loginHome.create(recursive: true);
    final generatedCert = File(p.join(loginHome.path, '.cloudflared', 'cert.pem'));
    final environment = NetworkProxy.processEnvironment()
      ..['HOME'] = loginHome.path
      ..['USERPROFILE'] = loginHome.path;

    try {
      final process = await Process.start(bin, ['tunnel', 'login'], environment: environment);
      // 自动打开只交给 cloudflared。应用仅提供完整链接供用户手动复制，避免重复标签页。
      final output = CloudflaredLoginOutput(onLoginUrl: onLoginUrl);
      final results = await Future.wait<Object>([
        process.exitCode,
        output.collect(process.stdout, process.stderr),
      ]);
      final exitCode = results[0] as int;
      if (await generatedCert.exists()) {
        await certFile.parent.create(recursive: true);
        if (await certFile.exists()) await certFile.delete();
        await generatedCert.copy(certFile.path);
        if (backup != null && await backup.exists()) await backup.delete();
        return CloudflareLoginResult.done;
      }

      if (backup != null && await backup.exists()) {
        await backup.rename(certFile.path);
      }
      return CloudflareLoginResult.failed('登录未完成 (exit $exitCode)：${results[1]}');
    } catch (_) {
      if (backup != null && await backup.exists() && !await certFile.exists()) {
        await backup.rename(certFile.path);
      }
      rethrow;
    } finally {
      onLoginUrl?.call(null);
      if (await loginHome.exists()) {
        try {
          await loginHome.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<String> createTunnel(String bin, String tunnelName) async {
    final originCert = await _requireOriginCert();
    final staging = await Directory(await AppPaths.cloudflareDir).createTemp('.create-tunnel-');
    final pending = File(p.join(staging.path, 'credentials.json'));
    try {
      return await CloudflaredTunnelSetup(
        run: (args) =>
            CloudflaredCli.runDetailed(bin, ['tunnel', '--origincert', originCert, ...args]),
        adoptCreatedCredentials: (id) => _adoptTunnelCredentials(id, pending),
        hasExistingCredentials: (id) async =>
            await ensureTunnelCredentials(id) &&
            await CloudflaredTunnelSetup.credentialsMatch(
              File(await AppPaths.credentialsPath(id)),
              id,
            ),
      ).create(tunnelName, pending.path);
    } finally {
      // 创建后若凭据收纳失败，保留文件供恢复，不能删掉远端 Tunnel 唯一的运行凭据。
      if (!await pending.exists()) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// 确保域名 DNS 指向指定 Tunnel。
  ///
  /// cloudflared 即使 exitCode=0，也可能把不属于当前 cert Zone 的 hostname
  /// 当成相对名称并追加 Zone，因此必须检查成功输出中的实际 hostname。
  Future<void> routeDns(String bin, String tunnelId, String domain) async {
    final originCert = await _requireOriginCert();
    try {
      final result = await CloudflaredCli.runDetailed(bin, [
        'tunnel',
        '--origincert',
        originCert,
        'route',
        'dns',
        '--overwrite-dns',
        tunnelId,
        domain,
      ]);
      final actualHostname = _findUnexpectedDnsHostname(result.combinedOutput, domain);
      if (actualHostname != null) {
        throw Exception(
          'DNS-ZONE-MISMATCH：当前 cert.pem 不属于 $domain 对应的 Cloudflare Zone。'
          'cloudflared 实际配置的是 $actualHostname，而不是 $domain。',
        );
      }
    } catch (error) {
      final message = '$error';
      if (_isDnsAuthorizationError(message)) {
        throw Exception('DNS 路由创建失败：当前 Cloudflare 登录凭据无权管理 $domain。\n$message');
      }
      rethrow;
    }
  }

  /// 创建或修复 DNS；Zone 不匹配或权限错误时强制重新授权一次，
  /// 最终还要通过 1.1.1.1 DoH 验证真实域名已经可解析。
  Future<void> ensureDnsRoute(
    String bin,
    String tunnelId,
    String domain, {
    void Function(String?)? onLoginUrl,
  }) async {
    try {
      await routeDns(bin, tunnelId, domain);
    } catch (error) {
      if (!_shouldReloginForDns('$error')) rethrow;

      final login = await loginCloudflare(bin, force: true, onLoginUrl: onLoginUrl);
      if (!login.success) {
        throw Exception(login.error ?? 'Cloudflare 重新授权未完成');
      }
      await routeDns(bin, tunnelId, domain);
    }

    await waitForPublicDns(domain);
  }

  Future<void> waitForPublicDns(
    String domain, {
    int attempts = 10,
    Duration interval = const Duration(seconds: 1),
  }) async {
    String? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        if (await isPublicDnsResolved(domain)) return;
        lastError = '1.1.1.1 仍未返回可用记录';
      } catch (error) {
        lastError = '$error';
      }
      if (attempt < attempts - 1) await Future<void>.delayed(interval);
    }
    throw Exception('DNS 路由命令已执行，但公网 DNS 验证未通过：$domain。${lastError == null ? '' : ' $lastError'}');
  }

  /// 使用 Cloudflare 1.1.1.1 DoH 绕过本机/路由器的 NXDOMAIN 负缓存。
  Future<bool> isPublicDnsResolved(String domain) async {
    final client = NetworkProxy.createHttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final uri = Uri.https('cloudflare-dns.com', '/dns-query', {'name': domain, 'type': 'A'});
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final response = await request.close().timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) {
        throw Exception('DoH HTTP ${response.statusCode}');
      }
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) return false;
      if (json['Status'] != 0) return false;
      final answers = json['Answer'];
      return answers is List && answers.isNotEmpty;
    } finally {
      client.close();
    }
  }

  String? _findUnexpectedDnsHostname(String output, String domain) {
    final normalized = normalizeDomain(domain);
    if (normalized.isEmpty || output.isEmpty) return null;
    final pattern = RegExp(
      '${RegExp.escape(normalized)}\\.([a-z0-9-]+(?:\\.[a-z0-9-]+)+)',
      caseSensitive: false,
    );
    final match = pattern.firstMatch(output);
    return match?.group(0)?.replaceAll(RegExp(r'[.,;:]$'), '');
  }

  bool _shouldReloginForDns(String message) {
    return _isDnsAuthorizationError(message) || message.toLowerCase().contains('dns-zone-mismatch');
  }

  bool _isDnsAuthorizationError(String message) {
    final text = message.toLowerCase();
    return text.contains('1003') ||
        text.contains('unauthorized') ||
        text.contains('not authorized') ||
        text.contains('permission') ||
        text.contains('无权管理') ||
        text.contains('未找到当前环境的 cloudflare cert.pem');
  }

  /// 旧版本的 Tunnel JSON 可以安全复制到当前环境；账号级 cert.pem 不迁移。
  /// Debug / Release 必须分别登录，避免不同账号或 Zone 的 cert.pem 互相污染。
  Future<void> migrateLegacyCloudflareCredentials([String? tunnelId]) async {
    if (tunnelId == null || tunnelId.isEmpty) return;
    await ensureTunnelCredentials(tunnelId);
  }

  Future<bool> ensureTunnelCredentials(String tunnelId) async {
    final target = File(await AppPaths.credentialsPath(tunnelId));
    if (await target.exists()) return true;

    final candidates = <File>[
      File(p.join(await AppPaths.configDir, '$tunnelId.json')),
      File(await AppPaths.legacyCredentialsPath(tunnelId)),
    ];
    for (final source in candidates) {
      if (!await source.exists()) continue;
      await target.parent.create(recursive: true);
      await source.copy(target.path);
      return true;
    }
    return false;
  }

  Future<String> _requireOriginCert() async {
    await migrateLegacyCloudflareCredentials();
    final path = await AppPaths.originCertPath;
    if (!await File(path).exists()) {
      throw Exception('未找到当前环境的 Cloudflare cert.pem，请重新登录 Cloudflare');
    }
    return path;
  }

  Future<bool> _adoptTunnelCredentials(String tunnelId, File pendingCredentials) async {
    final target = File(await AppPaths.credentialsPath(tunnelId));
    if (await CloudflaredTunnelSetup.credentialsMatch(pendingCredentials, tunnelId)) {
      await target.parent.create(recursive: true);
      await pendingCredentials.rename(target.path);
      return true;
    }
    return await ensureTunnelCredentials(tunnelId) &&
        await CloudflaredTunnelSetup.credentialsMatch(target, tunnelId);
  }

  Future<GlobalConfig> writeTunnelConfig(GlobalConfig config, String tunnelId) async {
    final credentialsFile = await AppPaths.credentialsPath(tunnelId);
    final configPath = await AppPaths.cloudflaredConfigPath;
    if (!await ensureTunnelCredentials(tunnelId)) {
      throw Exception('缺少 Tunnel credentials：$credentialsFile');
    }

    await File(configPath).writeAsString(
      TunnelConfigYml.build(
        tunnelId: tunnelId,
        credentialsFile: credentialsFile,
        hostname: config.domain,
        serviceUrl: config.localServiceUrl,
      ),
    );

    return config.copyWith(tunnelId: tunnelId);
  }

  Future<bool> openUrl(String url) async {
    try {
      ProcessResult result;
      if (Platform.isWindows) {
        result = await Process.run('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        result = await Process.run('open', [url]);
      } else {
        result = await Process.run('xdg-open', [url]);
      }
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static const githubReleasesUrl = 'https://github.com/cloudflare/cloudflared/releases/latest';

  String get githubAssetName {
    final platformAsset = desktopPlatform.cloudflaredAssetName;
    if (platformAsset != null) return platformAsset;
    if (Platform.isWindows) return 'cloudflared-windows-amd64.exe';
    final arch = _isArm64 ? 'arm64' : 'amd64';
    return 'cloudflared-linux-$arch';
  }

  String get managedBinName => Platform.isWindows ? 'cloudflared.exe' : 'cloudflared';

  String get _downloadUrl {
    final base = 'https://github.com/cloudflare/cloudflared/releases/download/$cloudflaredVersion';
    return '$base/$githubAssetName';
  }

  bool get _isArm64 {
    if (Platform.version.contains('arm64')) return true;
    final arch = Platform.environment['PROCESSOR_ARCHITECTURE']?.toLowerCase() ?? '';
    return arch.contains('arm');
  }

  String _homeDir() {
    return Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  }
}
