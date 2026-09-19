import 'dart:io';

import 'package:codexter/platform/desktop_platform.dart';
import 'package:codexter/platform/macos/macos_adapter.dart';
import 'package:codexter/platform/windows/windows_adapter.dart';
import 'package:codexter/services/setup_service.dart';
import 'package:codexter/utils/win_kill_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('平台入口仅选择实现，不调用原生插件', () {
    expect(desktopPlatformFor('windows'), isA<WindowsAdapter>());
    expect(desktopPlatformFor('macos'), isA<MacosAdapter>());
    expect(desktopPlatform.runtimeType, desktopPlatformFor(Platform.operatingSystem).runtimeType);
  });

  test('Windows 显式开放现有能力，Mac 只开放目录选择', () {
    final windows = desktopPlatformFor('windows');
    final mac = desktopPlatformFor('macos');
    expect(windows.supports(DesktopFeature.builtinComputerUse), isTrue);
    expect(windows.supports(DesktopFeature.inAppUpdate), isTrue);
    expect(windows.supports(DesktopFeature.directoryPicker), isTrue);
    expect(mac.supports(DesktopFeature.builtinComputerUse), isFalse);
    expect(mac.supports(DesktopFeature.inAppUpdate), isFalse);
    expect(mac.supports(DesktopFeature.directoryPicker), isTrue);
    expect(windows.workspacePathHint, r'C:\Projects\my-project');
    expect(mac.workspacePathHint, startsWith('/Users/'));
  });

  test('未适配的平台默认不开放功能', () {
    for (final os in ['linux', 'unknown']) {
      final adapter = desktopPlatformFor(os);
      for (final feature in DesktopFeature.values) {
        expect(adapter.supports(feature), isFalse, reason: '$os / $feature');
      }
    }
  });

  test('Windows 钩子不接管现有业务，不注册退出或触发下载安装', () async {
    final adapter = desktopPlatformFor('windows');
    var called = false;
    final detach = adapter.attachLifecycle(
      shutdown: () async {
        called = true;
      },
    );
    expect(await adapter.handleWindowClose(), isFalse);
    expect(await adapter.requestExit(), isFalse);
    expect(await adapter.configureTrayIcon(), isFalse);
    expect(
      await adapter.installCloudflared(
        source: Uri.parse('unused://no-network'),
        targetPath: '',
        onProgress: (_, _) {
          called = true;
        },
      ),
      isFalse,
    );
    expect(adapter.cloudflaredAssetName, isNull);
    detach();
    detach();
    expect(called, isFalse);
  });

  test('Windows 原下载名称保持不变', () {
    expect(SetupService().githubAssetName, 'cloudflared-windows-amd64.exe');
  }, skip: !Platform.isWindows);

  test('非 Windows 环境沿用原 Job 的平台保护，不打开 Windows 动态库', () {
    expect(WinKillOnCloseJob.bindCurrentProcess(), isFalse);
    expect(WinKillOnCloseJob.assignPid(pid), isFalse);
    expect(WinKillOnCloseJob.boundCurrentProcess, isFalse);
  }, skip: Platform.isWindows);

  test('共享业务不得直接依赖平台实现目录', () {
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.startsWith('lib/platform/')) continue;
      final source = file.readAsStringSync();
      expect(source, isNot(contains('platform/macos/')), reason: path);
      expect(source, isNot(contains('platform/windows/')), reason: path);
    }
  });
}
