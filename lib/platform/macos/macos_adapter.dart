import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

import '../../app_info.dart';
import '../desktop_adapter.dart';
import 'macos_cloudflared.dart';
import 'macos_lifecycle.dart';

/// macOS 基础适配；没有明确适配的功能保持关闭。
class MacosAdapter extends DesktopAdapter {
  const MacosAdapter();

  @override
  bool supports(DesktopFeature feature) =>
      const {DesktopFeature.directoryPicker, DesktopFeature.updateCheck}.contains(feature);

  @override
  bool get usesNativeWindowChrome => true;

  @override
  String get workspacePathHint => '/Users/you/Projects/my-project';

  @override
  String get cloudflaredAssetName => MacosCloudflared.currentAssetName;

  @override
  void Function() attachLifecycle({required Future<void> Function() shutdown}) =>
      MacosLifecycle(shutdown: shutdown).attach();

  @override
  Future<bool> handleWindowClose() async {
    await windowManager.hide();
    return true;
  }

  @override
  Future<bool> requestExit() async {
    await MacosLifecycle.requestExit();
    return true;
  }

  @override
  Future<bool> configureTrayIcon() async {
    // 复用彩色 Logo；不能把不透明背景作为单色模板，否则只剩方块。
    final data = await rootBundle.load(appLogoAsset);
    final directory = await getTemporaryDirectory();
    await directory.create(recursive: true);
    final icon = File(p.join(directory.path, '$appConfigDirName-tray.png'));
    await icon.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    await tray.trayManager.setIcon(icon.path, isTemplate: false, iconSize: 18);
    return true;
  }

  @override
  Future<bool> installCloudflared({
    required Uri source,
    required String targetPath,
    BinaryDownloadProgress? onProgress,
  }) async {
    await MacosCloudflared().install(source, targetPath, onProgress: onProgress);
    return true;
  }
}
