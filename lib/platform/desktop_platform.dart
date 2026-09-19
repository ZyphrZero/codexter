import 'dart:io';

import 'desktop_adapter.dart';
import 'macos/macos_adapter.dart';
import 'windows/windows_adapter.dart';

export 'desktop_adapter.dart' show DesktopAdapter, DesktopFeature;

/// 共享业务只导入此入口；构造适配器时不启动进程、不注册插件。
final DesktopAdapter desktopPlatform = desktopPlatformFor(Platform.operatingSystem);

/// 使用运行平台分流，不能用 dart.library.io 区分 Windows 与 macOS。
DesktopAdapter desktopPlatformFor(String operatingSystem) => switch (operatingSystem) {
  'windows' => const WindowsAdapter(),
  'macos' => const MacosAdapter(),
  _ => const DesktopAdapter(),
};
