import 'dart:async';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 使用 Flutter 标准退出回调，不另建 Swift/Dart 退出协议。
class MacosLifecycle with WidgetsBindingObserver {
  MacosLifecycle({required this.shutdown, this.timeout = const Duration(seconds: 15)});

  final Future<void> Function() shutdown;
  final Duration timeout;
  Future<void>? _shutdownTask;
  bool _attached = false;

  void Function() attach() {
    if (!_attached) {
      WidgetsBinding.instance.addObserver(this);
      _attached = true;
    }
    return detach;
  }

  void detach() {
    if (!_attached) return;
    WidgetsBinding.instance.removeObserver(this);
    _attached = false;
  }

  static Future<void> requestExit() async {
    await ServicesBinding.instance.exitApplication(AppExitType.cancelable);
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    try {
      // 超时不代表任务停止；保留进行中的任务，避免重试时并发清理同一批服务。
      await (_shutdownTask ??= _stopServices()).timeout(timeout);
      return AppExitResponse.exit;
    } catch (error) {
      // 失败时保留窗口和托盘，允许用户重试；绝不跳过清理直接退出。
      debugPrint('macOS 退出清理未完成，已取消退出：$error');
      return AppExitResponse.cancel;
    }
  }

  Future<void> _stopServices() async {
    try {
      // 将同步异常也转为 Future，确保任务缓存已完成赋值再处理失败。
      await Future<void>.sync(shutdown);
    } catch (_) {
      _shutdownTask = null;
      rethrow;
    }
  }
}
