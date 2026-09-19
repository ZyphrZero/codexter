import Cocoa
import FlutterMacOS

/// Mac 原生适配集中于此；窗口入口只调用，不向 Dart 业务散布环境修补。
enum MacOSIntegration {
  static func prepareEnvironment() {
    let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    let path = ProcessInfo.processInfo.environment["PATH"] ?? systemPath
    var entries = path.components(separatedBy: ":").filter { !$0.isEmpty }
    if entries.isEmpty { entries = systemPath.components(separatedBy: ":") }
    // 只补缺少的目录，保留虚拟环境和用户原有 PATH 优先级。
    for entry in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"] {
      if !entries.contains(entry) { entries.append(entry) }
    }
    // 必须早于 FlutterViewController 创建，后续 Dart 子进程才能继承。
    setenv("PATH", entries.joined(separator: ":"), 1)
  }

  /// 保留系统标题栏和原生按钮，仅同步窗口级外观与底色。
  static func makeAppearanceChannel(
    window: NSWindow,
    controller: FlutterViewController
  ) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(
      name: "com.codexter/window-appearance",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak window] call, result in
      guard call.method == "setAppearance" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let window = window else {
        result(FlutterError(code: "window_closed", message: "主窗口已关闭", details: nil))
        return
      }
      guard let args = call.arguments as? [String: Any],
            let dark = args["dark"] as? Bool,
            let background = args["background"] as? NSNumber,
            background.doubleValue.isFinite,
            background.doubleValue >= 0,
            background.doubleValue <= Double(UInt32.max),
            background.doubleValue.rounded(.towardZero) == background.doubleValue,
            background.uint32Value >> 24 == 255 else {
        result(FlutterError(code: "invalid_appearance", message: "窗口外观参数无效", details: nil))
        return
      }
      let argb = background.uint32Value
      // 不设置 NSApp.appearance，避免干扰系统主题检测与其他窗口。
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      window.backgroundColor = NSColor(
        srgbRed: CGFloat((argb >> 16) & 255) / 255,
        green: CGFloat((argb >> 8) & 255) / 255,
        blue: CGFloat(argb & 255) / 255,
        alpha: 1
      )
      // 透明的是标题栏系统材质，不是整扇窗口；标题栏透出与侧栏一致的不透明底色。
      // 不改 styleMask 或启用 fullSizeContentView，内容不会侵入系统按钮区域。
      window.titlebarAppearsTransparent = true
      window.isOpaque = true
      window.invalidateShadow()
      result(nil)
    }
    return channel
  }

  static func reopen(_ application: NSApplication, window: NSWindow?) -> Bool {
    guard let window = window else { return false }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
    return true
  }
}
