import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../../app_info.dart';
import '../../stores/app_state.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/widgets/app_about_dialog.dart';
import '../../ui/widgets/app_dialog.dart';
import '../../ui/widgets/app_update_dialog.dart';
import '../../ui/widgets/settings_dialog.dart';
import '../../utils/app_paths.dart';
import 'macos_window_appearance.dart';

/// 菜单交给 AppKit 绘制；内容区不再占用自绘标题栏的高度。
class MacosWindowFrame extends StatefulWidget {
  const MacosWindowFrame({super.key, required this.appState, required this.child});

  final AppState appState;
  final Widget child;

  @override
  State<MacosWindowFrame> createState() => _MacosWindowFrameState();
}

class _MacosWindowFrameState extends State<MacosWindowFrame> {
  final _appearance = MacosWindowAppearance();
  List<PlatformMenuItem>? _menus;
  bool? _menuDarkMode;
  bool _dialogOpen = false;

  @override
  void didUpdateWidget(covariant MacosWindowFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appState != widget.appState) _menus = null;
  }

  @override
  void dispose() {
    _appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.appState,
    builder: (context, _) {
      final darkMode = widget.appState.darkMode;
      final theme = darkMode ? AppTheme.dark : AppTheme.light;
      // 标题栏与侧栏共用配色；首次启动、手动切换及跟随系统的主题变化均走同一入口。
      unawaited(_appearance.update(darkMode: darkMode, background: AppTones.surfaceSunken(theme)));
      // 日志和进程状态频繁通知时，不重建系统菜单、打断正在展开的菜单。
      if (_menus == null || _menuDarkMode != darkMode) {
        _menuDarkMode = darkMode;
        _menus = _buildMenus(darkMode);
      }
      return PlatformMenuBar(
        menus: _menus!,
        child: SizedBox.expand(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 横跨侧栏和内容区，与页面标题下方的分割线共用边框色。
              Container(
                key: const ValueKey('macos-titlebar-divider'),
                height: 1,
                color: theme.colorScheme.border,
              ),
              Expanded(child: widget.child),
            ],
          ),
        ),
      );
    },
  );

  List<PlatformMenuItem> _buildMenus(bool darkMode) => [
    PlatformMenu(
      label: appName,
      menus: [
        PlatformMenuItemGroup(
          members: [
            _command('关于 $appName', _showAbout),
            _command(
              '设置…',
              () => _showDialog((context) => SettingsDialog.show(context, widget.appState)),
              shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
            ),
          ],
        ),
        ..._provided([PlatformProvidedMenuItemType.servicesSubmenu]),
        PlatformMenuItemGroup(
          members: _provided([
            PlatformProvidedMenuItemType.hide,
            PlatformProvidedMenuItemType.hideOtherApplications,
            PlatformProvidedMenuItemType.showAllApplications,
          ]).toList(),
        ),
        // 系统退出走 FlutterAppDelegate，再交给现有 MacosLifecycle 清理服务。
        ..._provided([PlatformProvidedMenuItemType.quit]),
      ],
    ),
    PlatformMenu(
      label: '文件',
      menus: [
        PlatformMenuItemGroup(members: [_command('打开配置目录', _openConfigDirectory)]),
        _command(
          '关闭窗口',
          windowManager.close,
          shortcut: const SingleActivator(LogicalKeyboardKey.keyW, meta: true),
        ),
      ],
    ),
    PlatformMenu(
      label: '编辑',
      menus: [
        PlatformMenuItemGroup(
          members: [
            _editing(
              '撤销',
              LogicalKeyboardKey.keyZ,
              const UndoTextIntent(SelectionChangedCause.keyboard),
            ),
            _editing(
              '重做',
              LogicalKeyboardKey.keyZ,
              const RedoTextIntent(SelectionChangedCause.keyboard),
              shift: true,
            ),
          ],
        ),
        _editing(
          '剪切',
          LogicalKeyboardKey.keyX,
          const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
        ),
        _editing('复制', LogicalKeyboardKey.keyC, CopySelectionTextIntent.copy),
        _editing(
          '粘贴',
          LogicalKeyboardKey.keyV,
          const PasteTextIntent(SelectionChangedCause.keyboard),
        ),
        _editing(
          '全选',
          LogicalKeyboardKey.keyA,
          const SelectAllTextIntent(SelectionChangedCause.keyboard),
        ),
      ],
    ),
    PlatformMenu(
      label: '视图',
      menus: [
        PlatformMenuItemGroup(
          members: [
            _command(
              darkMode ? '切换为浅色模式' : '切换为深色模式',
              () => widget.appState.setThemeMode(!widget.appState.darkMode),
            ),
          ],
        ),
        ..._provided([PlatformProvidedMenuItemType.toggleFullScreen]),
      ],
    ),
    PlatformMenu(
      label: '窗口',
      menus: [
        _command('显示主窗口', _showMainWindow),
        ..._provided([
          PlatformProvidedMenuItemType.minimizeWindow,
          PlatformProvidedMenuItemType.zoomWindow,
          PlatformProvidedMenuItemType.arrangeWindowsInFront,
        ]),
      ],
    ),
    PlatformMenu(
      label: '帮助',
      menus: [
        _command('GitHub', _openGithub),
        _command(
          '检查更新',
          () => _showDialog((context) => AppUpdateDialog.checkAndShow(context, widget.appState)),
        ),
        PlatformMenuItemGroup(members: [_command('关于 $appName', _showAbout)]),
      ],
    ),
  ];

  Iterable<PlatformMenuItem> _provided(List<PlatformProvidedMenuItemType> types) => types
      .where(PlatformProvidedMenuItem.hasMenu)
      .map((type) => PlatformProvidedMenuItem(type: type));

  PlatformMenuItem _command(
    String label,
    Future<void> Function() action, {
    SingleActivator? shortcut,
  }) =>
      PlatformMenuItem(label: label, shortcut: shortcut, onSelected: () => unawaited(_run(action)));

  PlatformMenuItem _editing(
    String label,
    LogicalKeyboardKey key,
    Intent intent, {
    bool shift = false,
  }) => PlatformMenuItem(
    label: label,
    shortcut: SingleActivator(key, meta: true, shift: shift),
    onSelected: () {
      // 菜单自身不抢输入焦点；编辑指令作用于当前输入框，包括弹窗中的输入框。
      final target = FocusManager.instance.primaryFocus?.context;
      if (target != null && target.mounted) Actions.maybeInvoke(target, intent);
    },
  );

  Future<void> _run(Future<void> Function() action) async {
    if (!mounted) return;
    try {
      await action();
    } catch (error, stack) {
      debugPrint('macOS 菜单操作失败：$error\n$stack');
      if (!mounted) return;
      await AppDialog.show<void>(context: context, title: '操作失败', content: Text('$error'));
    }
  }

  Future<void> _showMainWindow() async {
    // window_manager.show 已包含最小化恢复，避免重复触发恢复动画。
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _showDialog(Future<void> Function(BuildContext) show) async {
    if (_dialogOpen) {
      await _showMainWindow();
      return;
    }
    _dialogOpen = true;
    try {
      // 系统菜单在窗口隐藏后仍可操作，必须先恢复窗口再显示弹窗。
      await _showMainWindow();
      if (!mounted) return;
      await show(context);
    } finally {
      _dialogOpen = false;
    }
  }

  Future<void> _showAbout() =>
      _showDialog((context) => AppAboutDialog.show(context, widget.appState));

  Future<void> _openGithub() async {
    if (!await widget.appState.setupService.openUrl(appGithubUrl)) {
      throw const FileSystemException('无法打开 GitHub 项目页面');
    }
  }

  Future<void> _openConfigDirectory() async {
    final path = await AppPaths.configDir;
    final result = await Process.run('/usr/bin/open', [path]);
    if (result.exitCode != 0) throw const FileSystemException('无法打开配置目录');
  }
}
