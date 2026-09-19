import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var appearanceChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    MacOSIntegration.prepareEnvironment()
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    appearanceChannel = MacOSIntegration.makeAppearanceChannel(
      window: self,
      controller: flutterViewController
    )

    super.awakeFromNib()
  }
}
