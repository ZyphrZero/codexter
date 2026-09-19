import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 只同步当前 Mac 窗口的外观，不改变系统或整个应用的外观偏好。
class MacosWindowAppearance {
  static const channel = MethodChannel('com.codexter/window-appearance');

  (bool, int)? _requested;
  Future<void> _pending = Future<void>.value();
  bool _disposed = false;

  Future<void> update({required bool darkMode, required Color background}) {
    final requested = (darkMode, background.withValues(alpha: 1).toARGB32());
    if (_disposed || _requested == requested) return _pending;
    _requested = requested;
    // 原生调用串行执行；快速切换时跳过尚未发送的旧主题，防止旧回调覆盖新主题。
    _pending = _pending.then((_) async {
      if (_disposed || _requested != requested) return;
      try {
        await channel.invokeMethod<void>('setAppearance', {
          'dark': requested.$1,
          'background': requested.$2,
        });
      } catch (error) {
        if (_requested == requested) _requested = null;
        // 原生代码更新后仅热重载可能尚未注册通道；不要让外观同步失败阻断主界面。
        debugPrint('macOS 窗口外观同步失败，请完全退出后重新运行：$error');
      }
    });
    return _pending;
  }

  void dispose() {
    _disposed = true;
    _requested = null;
  }
}
