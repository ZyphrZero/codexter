import '../desktop_adapter.dart';

/// Windows 继续使用原来的安装、托盘、退出和进程实现，钩子均不接管。
class WindowsAdapter extends DesktopAdapter {
  const WindowsAdapter();

  @override
  bool supports(DesktopFeature feature) => const {
    DesktopFeature.directoryPicker,
    DesktopFeature.builtinComputerUse,
    DesktopFeature.updateCheck,
    DesktopFeature.inAppUpdate,
  }.contains(feature);
}
