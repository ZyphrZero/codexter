import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../app_info.dart';
import '../stores/app_state.dart';
import '../ui/widgets/app_window_title_bar.dart';
import 'desktop_platform.dart';
import 'macos/macos_window_frame.dart';

/// 窗口配置和内容分流使用同一能力，避免原生标题栏与自绘标题栏同时出现。
WindowOptions desktopWindowOptionsFor(DesktopAdapter platform) => WindowOptions(
  size: const Size(1120, 720),
  minimumSize: const Size(960, 640),
  title: appName,
  titleBarStyle: platform.usesNativeWindowChrome ? TitleBarStyle.normal : TitleBarStyle.hidden,
  windowButtonVisibility: platform.usesNativeWindowChrome,
  backgroundColor: const Color(0x00000000),
);

/// 共享入口只选择窗口容器，Windows 原有菜单及窗口按钮保持不变。
class DesktopWindowFrame extends StatelessWidget {
  const DesktopWindowFrame({super.key, required this.appState, required this.child});

  final AppState appState;
  final Widget child;

  @override
  Widget build(BuildContext context) => desktopPlatform.usesNativeWindowChrome
      ? MacosWindowFrame(appState: appState, child: child)
      : AppWindowFrame(appState: appState, child: child);
}
