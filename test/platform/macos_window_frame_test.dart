import 'dart:convert';
import 'dart:io';

import 'package:codexter/platform/desktop_platform.dart';
import 'package:codexter/platform/desktop_window.dart';
import 'package:codexter/platform/macos/macos_window_frame.dart';
import 'package:codexter/platform/macos/macos_window_appearance.dart';
import 'package:codexter/ui/theme/app_theme.dart';
import 'package:codexter/stores/app_state.dart';
import 'package:codexter/ui/widgets/app_window_title_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:window_manager/window_manager.dart';

class _MenuAppState extends AppState {
  bool _dark = false;

  @override
  bool get darkMode => _dark;

  @override
  Future<void> setThemeMode(bool? value) async {
    _dark = value ?? false;
    notifyListeners();
  }

  void logChanged() => notifyListeners();
}

Iterable<PlatformMenuItem> _flatten(Iterable<PlatformMenuItem> items) sync* {
  for (final item in items) {
    yield item;
    yield* _flatten(item is PlatformMenu ? item.menus : item.members);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);
  const windowChannel = MethodChannel('window_manager');
  final menuCalls = <MethodCall>[];
  final windowCalls = <String>[];
  final appearanceCalls = <MethodCall>[];
  late _MenuAppState appState;
  var minimized = true;

  setUp(() {
    appState = _MenuAppState();
    menuCalls.clear();
    windowCalls.clear();
    appearanceCalls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(MacosWindowAppearance.channel, (
      call,
    ) async {
      appearanceCalls.add(call);
      return null;
    });
    minimized = true;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.menu, (call) async {
      menuCalls.add(call);
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(windowChannel, (call) async {
      windowCalls.add(call.method);
      if (call.method == 'isMinimized') return minimized;
      if (call.method == 'isMaximized') return false;
      if (call.method == 'restore') minimized = false;
      return null;
    });
    PackageInfo.setMockInitialValues(
      appName: 'Codexter',
      packageName: 'com.codexter.codexter',
      version: '1.0.6',
      buildNumber: '7',
      buildSignature: '',
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.menu, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(windowChannel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(MacosWindowAppearance.channel, null);
    appState.dispose();
  });

  Future<void> pumpFrame(WidgetTester tester, {Widget? child}) async {
    await tester.pumpWidget(
      ShadcnApp(
        home: MacosWindowFrame(
          appState: appState,
          child: child ?? const SizedBox.expand(key: ValueKey('content')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  PlatformMenuItem item(WidgetTester tester, String label) {
    final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
    return _flatten(bar.menus).firstWhere((item) => item.label == label);
  }

  test('Mac 使用系统标题栏和原生按钮，Windows 保留原始窗口配置', () {
    final mac = desktopWindowOptionsFor(desktopPlatformFor('macos'));
    final windows = desktopWindowOptionsFor(desktopPlatformFor('windows'));
    expect(mac.titleBarStyle, TitleBarStyle.normal);
    expect(mac.windowButtonVisibility, isTrue);
    expect(windows.titleBarStyle, TitleBarStyle.hidden);
    expect(windows.windowButtonVisibility, isFalse);
    expect(windows.size, const Size(1120, 720));
    expect(windows.minimumSize, const Size(960, 640));
    expect(mac.size, windows.size);
    expect(windows.title, 'Codexter');
    expect(menuCalls, isEmpty);
    expect(windowCalls, isEmpty);
  });

  testWidgets('Windows 仍绘制原菜单与标题栏，不注册 Mac 菜单', (tester) async {
    await tester.pumpWidget(
      ShadcnApp(
        home: DesktopWindowFrame(appState: appState, child: const SizedBox.expand()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppWindowTitleBar), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('视图'), findsOneWidget);
    expect(find.text('帮助'), findsOneWidget);
    expect(find.byType(PlatformMenuBar), findsNothing);
    expect(menuCalls, isEmpty);
    expect(appearanceCalls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);

  testWidgets('菜单提交到原生通道，Mac 内容区不再绘制标题和按钮', (tester) async {
    await pumpFrame(tester);
    final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
    expect(bar.menus.map((menu) => menu.label), ['Codexter', '文件', '编辑', '视图', '窗口', '帮助']);
    expect(find.byType(AppWindowTitleBar), findsNothing);
    expect(find.text('文件'), findsNothing);
    expect(tester.getTopLeft(find.byKey(const ValueKey('content'))).dy, 1);
    expect(menuCalls.where((call) => call.method == 'Menu.setMenus'), isNotEmpty);
    expect(jsonEncode(menuCalls.last.arguments), contains('打开配置目录'));
    expect(item(tester, '检查更新').onSelected, isNotNull);
    final nativeTypes = _flatten(
      bar.menus,
    ).whereType<PlatformProvidedMenuItem>().map((item) => item.type).toSet();
    expect(
      nativeTypes,
      containsAll([
        PlatformProvidedMenuItemType.quit,
        PlatformProvidedMenuItemType.hide,
        PlatformProvidedMenuItemType.minimizeWindow,
        PlatformProvidedMenuItemType.toggleFullScreen,
      ]),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: macOS);

  testWidgets('主题操作有效且更新菜单，连续日志刷新不重复提交系统菜单', (tester) async {
    await pumpFrame(tester);
    // 固定 SDK 的 PlatformMenuBar 在首次更新时建立 descendants 缓存。
    appState.logChanged();
    await tester.pump();
    final writes = menuCalls.length;
    for (var i = 0; i < 5; i++) {
      appState.logChanged();
      await tester.pump();
    }
    expect(menuCalls.length, writes);
    item(tester, '切换为深色模式').onSelected!();
    await tester.pumpAndSettle();
    expect(appState.darkMode, isTrue);
    expect(item(tester, '切换为浅色模式').onSelected, isNotNull);
    expect(menuCalls.length, greaterThan(writes));
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: macOS);

  testWidgets('Mac 首次渲染同步标题栏底色，主题切换同步外观，日志刷新不重复发送', (tester) async {
    await pumpFrame(tester);
    expect(appearanceCalls, hasLength(1));
    expect(appearanceCalls.single.method, 'setAppearance');
    expect(appearanceCalls.single.arguments, {
      'dark': false,
      'background': AppTones.surfaceSunken(AppTheme.light).toARGB32(),
    });
    for (var i = 0; i < 5; i++) {
      appState.logChanged();
      await tester.pump();
    }
    expect(appearanceCalls, hasLength(1));
    await appState.setThemeMode(true);
    await tester.pumpAndSettle();
    expect(appearanceCalls, hasLength(2));
    expect(appearanceCalls.last.arguments, {
      'dark': true,
      'background': AppTones.surfaceSunken(AppTheme.dark).toARGB32(),
    });
    await appState.setThemeMode(false);
    await tester.pumpAndSettle();
    expect(appearanceCalls, hasLength(3));
    expect(appearanceCalls.last.arguments['dark'], false);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: macOS);

  testWidgets('启动前已有深色偏好时直接同步深色标题栏', (tester) async {
    await appState.setThemeMode(true);
    await pumpFrame(tester);
    expect(appearanceCalls, hasLength(1));
    expect(appearanceCalls.single.arguments['dark'], true);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: macOS);

  testWidgets('关闭窗口复用窗口事件，显示主窗口会恢复最小化并聚焦', (tester) async {
    await pumpFrame(tester);
    final close = item(tester, '关闭窗口');
    final shortcut = close.shortcut! as SingleActivator;
    expect(shortcut.trigger, LogicalKeyboardKey.keyW);
    expect(shortcut.meta, isTrue);
    close.onSelected!();
    await tester.pumpAndSettle();
    expect(windowCalls, ['close']);
    windowCalls.clear();
    item(tester, '显示主窗口').onSelected!();
    await tester.pumpAndSettle();
    expect(windowCalls, ['isMinimized', 'restore', 'show', 'focus']);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: macOS);

  testWidgets('编辑菜单保留输入框焦点，全选和剪切作用于当前文本', (tester) async {
    final controller = TextEditingController(text: '测试菜单编辑');
    addTearDown(controller.dispose);
    await pumpFrame(
      tester,
      child: Center(
        child: SizedBox(width: 300, child: TextField(controller: controller)),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    item(tester, '全选').onSelected!();
    await tester.pump();
    expect(
      controller.selection,
      TextSelection(baseOffset: 0, extentOffset: controller.text.length),
    );
    item(tester, '剪切').onSelected!();
    await tester.pumpAndSettle();
    expect(controller.text, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: macOS);

  testWidgets('从系统菜单显示关于时先恢复窗口，重复选择不叠加弹窗', (tester) async {
    await pumpFrame(tester);
    final about = item(tester, '关于 Codexter');
    about.onSelected!();
    about.onSelected!();
    await tester.pumpAndSettle();
    expect(windowCalls, containsAll(['show', 'restore', 'focus']));
    expect(find.text('关于 Codexter'), findsOneWidget);
    expect(find.byType(PlatformMenuBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: macOS);
}
