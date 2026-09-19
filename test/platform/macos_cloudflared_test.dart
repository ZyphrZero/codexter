import 'dart:ffi';
import 'dart:io';

import 'package:codexter/platform/macos/macos_cloudflared.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Mac arm64 与 Intel 下载包严格按 ABI 区分', () {
    expect(MacosCloudflared.assetNameFor(Abi.macosArm64), 'cloudflared-darwin-arm64.tgz');
    expect(MacosCloudflared.assetNameFor(Abi.macosX64), 'cloudflared-darwin-amd64.tgz');
    expect(() => MacosCloudflared.assetNameFor(Abi.windowsX64), throwsUnsupportedError);
  });

  group('Mac 安装事务与压缩包处理', () {
    late Directory root;
    late Directory input;
    late File target;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('codexter Mac 隔离测试 ');
      input = await Directory(p.join(root.path, 'payload')).create();
      target = File(p.join(root.path, 'bin', 'cloudflared'));
      await target.parent.create();
      await target.writeAsString('旧版本');
    });
    tearDown(() async {
      await root.delete(recursive: true);
    });

    Future<File> archive(List<String> names) async {
      final staging = await root.createTemp('archive-');
      final file = File(p.join(staging.path, 'bundle.tgz'));
      // 中文路径交给 workingDirectory；归档参数使用无盘符的相对路径，兼容 BSD/GNU tar。
      final archivePath = p.relative(file.path, from: input.path).replaceAll('\\', '/');
      final result = await Process.run('tar', [
        '-czf',
        archivePath,
        ...names,
      ], workingDirectory: input.path);
      expect(result.exitCode, 0, reason: '创建测试归档失败：${result.stderr}');
      return file;
    }

    Future<void> serve(
      List<int> bytes,
      Future<void> Function(Uri) action, {
      int status = HttpStatus.ok,
    }) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = status;
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      try {
        await action(Uri.parse('http://127.0.0.1:${server.port}/cloudflared.tgz'));
      } finally {
        await server.close(force: true);
      }
    }

    Future<void> expectOldTargetAndNoStaging() async {
      expect(await target.readAsString(), '旧版本');
      expect(target.parent.listSync().map((e) => p.basename(e.path)), ['cloudflared']);
    }

    test('中文和空格路径正常解压，只提取目标条目', () async {
      await File(p.join(input.path, 'cloudflared')).writeAsString('新版本');
      await File(p.join(input.path, 'extra.txt')).writeAsString('不能提取');
      final file = await archive(['cloudflared', 'extra.txt']);
      final binary = await MacosCloudflared.extractArchive(file.path);
      expect(await binary.readAsString(), '新版本');
      expect(File(p.join(file.parent.path, 'extra.txt')).existsSync(), isFalse);
    });

    test('相对归档路径正常解压，且不改变全局工作目录', () async {
      await File(p.join(input.path, 'cloudflared')).writeAsString('新版本');
      final file = await archive(['cloudflared']);
      final currentDirectory = Directory.current.path;
      // 系统临时目录可能在另一盘符，因此在项目缓存内另建目录，确保传入的真是相对路径。
      final local = await Directory('.dart_tool').createTemp('codexter 相对路径 ');
      addTearDown(() => local.delete(recursive: true));
      final copy = await file.copy(p.join(local.path, 'bundle.tgz'));
      final archivePath = p.relative(copy.absolute.path, from: currentDirectory);
      expect(p.isRelative(archivePath), isTrue);
      final binary = await MacosCloudflared.extractArchive(archivePath);
      expect(await binary.readAsString(), '新版本');
      expect(p.equals(binary.parent.path, copy.parent.absolute.path), isTrue);
      expect(Directory.current.path, currentDirectory);
    });

    test('缺少目标文件时明确失败', () async {
      await File(p.join(input.path, 'other')).writeAsString('不是目标');
      final file = await archive(['other']);
      await expectLater(MacosCloudflared.extractArchive(file.path), throwsFormatException);
    });

    test('损坏压缩包不能当作有效程序', () async {
      final file = File(p.join(root.path, 'broken.tgz'));
      await file.writeAsString('invalid gzip');
      await expectLater(MacosCloudflared.extractArchive(file.path), throwsFormatException);
    });

    test('拒绝空文件和目录', () async {
      final binary = File(p.join(input.path, 'cloudflared'));
      await binary.writeAsString('');
      final empty = await archive(['cloudflared']);
      await expectLater(MacosCloudflared.extractArchive(empty.path), throwsFormatException);
      await binary.delete();
      await Directory(binary.path).create();
      final directory = await archive(['cloudflared']);
      await expectLater(MacosCloudflared.extractArchive(directory.path), throwsFormatException);
    });

    test('拒绝把符号链接当作目标程序', () async {
      await Link(p.join(input.path, 'cloudflared')).create('other');
      final file = await archive(['cloudflared']);
      await expectLater(MacosCloudflared.extractArchive(file.path), throwsFormatException);
    }, skip: Platform.isWindows);

    test('校验通过才替换旧程序，结束后清理暂存目录', () async {
      await File(p.join(input.path, 'cloudflared')).writeAsString('新版本');
      final file = await archive(['cloudflared']);
      final bytes = await file.readAsBytes();
      final progress = <int>[];
      var validations = 0;
      final installer = MacosCloudflared(
        validateBinary: (binary) async {
          expect(await target.readAsString(), '旧版本');
          expect(await binary.readAsString(), '新版本');
          validations++;
        },
      );
      await serve(
        bytes,
        (uri) => installer.install(
          uri,
          target.path,
          onProgress: (received, total) {
            expect(total, bytes.length);
            progress.add(received);
          },
        ),
      );
      expect(validations, 1);
      expect(progress.last, bytes.length);
      expect(await target.readAsString(), '新版本');
      expect(target.parent.listSync().map((e) => p.basename(e.path)), ['cloudflared']);
    });

    test('HTTP 错误保留旧程序，不调用校验器', () async {
      var validated = false;
      final installer = MacosCloudflared(
        validateBinary: (_) async {
          validated = true;
        },
      );
      await serve([], (uri) async {
        await expectLater(installer.install(uri, target.path), throwsA(isA<HttpException>()));
      }, status: HttpStatus.notFound);
      expect(validated, isFalse);
      await expectOldTargetAndNoStaging();
    });

    test('解压失败保留旧程序并清理下载文件', () async {
      final installer = MacosCloudflared(validateBinary: (_) async {});
      await serve([1, 2, 3], (uri) async {
        await expectLater(installer.install(uri, target.path), throwsFormatException);
      });
      await expectOldTargetAndNoStaging();
    });

    test('执行校验失败不覆盖旧程序', () async {
      await File(p.join(input.path, 'cloudflared')).writeAsString('错误架构');
      final file = await archive(['cloudflared']);
      final installer = MacosCloudflared(
        validateBinary: (_) async {
          throw const FormatException('模拟无法运行');
        },
      );
      await serve(await file.readAsBytes(), (uri) async {
        await expectLater(installer.install(uri, target.path), throwsFormatException);
      });
      await expectOldTargetAndNoStaging();
    });

    test('Mac 本机执行权限及版本探测真实通过', () async {
      await File(
        p.join(input.path, 'cloudflared'),
      ).writeAsString('#!/bin/sh\nprintf "cloudflared version fixture\\n"\n');
      final file = await archive(['cloudflared']);
      await serve(await file.readAsBytes(), (uri) => MacosCloudflared().install(uri, target.path));
      final result = await Process.run(target.path, ['--version']);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('cloudflared version fixture'));
    }, skip: !Platform.isMacOS);
  });
}
