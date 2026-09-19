import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../desktop_adapter.dart';

/// macOS 下载、解压和校验独立实现，不改 Windows 的安装路径。
class MacosCloudflared {
  /// 可注入校验器，以便 Windows 上测试下载事务而不执行 Mac 二进制。
  MacosCloudflared({Future<void> Function(File)? validateBinary})
    : _validateBinary = validateBinary ?? _makeExecutableAndVerify;

  final Future<void> Function(File) _validateBinary;
  static const _networkTimeout = Duration(seconds: 30);

  static String get currentAssetName => assetNameFor(Abi.current());

  static String assetNameFor(Abi abi) => switch (abi) {
    Abi.macosArm64 => 'cloudflared-darwin-arm64.tgz',
    Abi.macosX64 => 'cloudflared-darwin-amd64.tgz',
    _ => throw UnsupportedError('不支持的 macOS 架构：$abi'),
  };

  Future<void> install(Uri source, String targetPath, {BinaryDownloadProgress? onProgress}) async {
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    // 与目标处于同一文件系统；验证通过前不动旧文件。
    final staging = await target.parent.createTemp('.cloudflared-');
    final client = HttpClient()..connectionTimeout = _networkTimeout;
    try {
      final request = await client.getUrl(source).timeout(_networkTimeout);
      final response = await request.close().timeout(_networkTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('下载 cloudflared 失败（HTTP ${response.statusCode}）', uri: source);
      }
      final archive = File(p.join(staging.path, 'cloudflared.tgz'));
      final sink = archive.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(_networkTimeout)) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, response.contentLength);
        }
      } finally {
        await sink.close();
      }
      final binary = await extractArchive(archive.path);
      await _validateBinary(binary);
      await binary.rename(target.path);
    } finally {
      client.close(force: true);
      try {
        await staging.delete(recursive: true);
      } catch (_) {
        // 临时目录清理不覆盖原始安装异常，也不能删除已安装的目标。
      }
    }
  }

  /// 只提取官方包中的 cloudflared 条目，并拒绝符号链接、目录及空文件。
  static Future<File> extractArchive(String archivePath) async {
    final archive = File(archivePath).absolute;
    final directory = archive.parent;
    // 由系统设置工作目录，tar 只接收文件名，避免 Windows 盘符被视为远程地址，
    // 也避免不同 tar 实现对中文绝对路径参数的编码差异。不修改进程的全局目录。
    final result = await Process.run('tar', [
      '-xzf',
      p.basename(archive.path),
      'cloudflared',
    ], workingDirectory: directory.path);
    if (result.exitCode != 0) {
      throw FormatException('解压 cloudflared 失败：${result.stderr}');
    }
    final binary = File(p.join(directory.path, 'cloudflared'));
    if (await FileSystemEntity.type(binary.path, followLinks: false) != FileSystemEntityType.file) {
      throw const FormatException('压缩包中缺少普通文件 cloudflared');
    }
    if (await binary.length() == 0) {
      throw const FormatException('压缩包中的 cloudflared 为空');
    }
    return binary;
  }

  static Future<void> _makeExecutableAndVerify(File binary) async {
    final chmod = await Process.run('/bin/chmod', ['+x', binary.path]);
    if (chmod.exitCode != 0) throw const FileSystemException('设置 cloudflared 执行权限失败');
    final process = await Process.start(binary.path, ['--version']);
    final output = Future.wait([process.stdout.drain<void>(), process.stderr.drain<void>()]);
    try {
      final code = await process.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          throw TimeoutException('cloudflared 版本探测超时');
        },
      );
      if (code != 0) throw const FormatException('下载的 cloudflared 无法运行');
    } finally {
      await output.timeout(const Duration(seconds: 2));
    }
  }
}
