import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var privacy: FlutterMethodChannel?
  private var cover: NSView?
  override func awakeFromNib() {
    let controller = FlutterViewController()
    let windowFrame = frame
    contentViewController = controller
    setFrame(windowFrame, display: true)
    title = "Six Tick"
    RegisterGeneratedPlugins(registry: controller)
    privacy = FlutterMethodChannel(name: "six_tick/privacy", binaryMessenger: controller.engine.binaryMessenger)
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemLocked),
      name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    DistributedNotificationCenter.default().addObserver(self, selector: #selector(systemLocked),
      name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(hideContent), name: NSWindow.didResignKeyNotification, object: self)
    NotificationCenter.default.addObserver(self, selector: #selector(showContent), name: NSWindow.didBecomeKeyNotification, object: self)
    super.awakeFromNib()
  }
  @objc private func systemLocked() { hideContent(); privacy?.invokeMethod("systemLocked", arguments: nil) }
  @objc private func hideContent() {
    guard cover == nil, let content = contentView else { return }
    let overlay = NSView(frame: content.bounds)
    overlay.wantsLayer = true; overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    overlay.autoresizingMask = [.width, .height]
    content.addSubview(overlay); cover = overlay
  }
  @objc private func showContent() { cover?.removeFromSuperview(); cover = nil }
}
