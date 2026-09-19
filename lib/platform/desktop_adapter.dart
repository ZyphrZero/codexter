/// 平台能力必须显式开放；新增 Windows 功能不会自动在其他平台启用。
enum DesktopFeature { directoryPicker, builtinComputerUse, updateCheck, inAppUpdate }

typedef BinaryDownloadProgress = void Function(int received, int total);

/// 对现有服务的补充接口，不复制业务实现。
///
/// 布尔异步钩子返回 false 表示未接管，由调用方继续执行原逻辑；
/// 已接管但失败必须抛错，不能回退到另一个平台的实现。
class DesktopAdapter {
  const DesktopAdapter();

  bool supports(DesktopFeature feature) => false;

  /// 默认沿用自绘标题栏；原生窗口与菜单由对应平台显式接管。
  bool get usesNativeWindowChrome => false;

  String get workspacePathHint => r'C:\Projects\my-project';

  String? get cloudflaredAssetName => null;

  /// 返回注销函数，生命周期与调用方的 Widget 一致。
  void Function() attachLifecycle({required Future<void> Function() shutdown}) => () {};

  Future<bool> handleWindowClose() async => false;

  Future<bool> requestExit() async => false;

  Future<bool> configureTrayIcon() async => false;

  Future<bool> installCloudflared({
    required Uri source,
    required String targetPath,
    BinaryDownloadProgress? onProgress,
  }) async => false;
}
