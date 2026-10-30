import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var privacy: FlutterMethodChannel?
  private var cover: UIView?

  override func application(_ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      privacy = FlutterMethodChannel(name: "six_tick/privacy", binaryMessenger: controller.binaryMessenger)
      privacy?.setMethodCallHandler { call, result in
        guard call.method == "copyCode", let args = call.arguments as? [String: Any],
              let code = args["code"] as? String else { result(FlutterMethodNotImplemented); return }
        let clear = args["clear"] as? Bool ?? true
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if clear { options[.expirationDate] = Date().addingTimeInterval(30) }
        UIPasteboard.general.setItems([["public.utf8-plain-text": code]], options: options)
        result(nil)
      }
    }
    NotificationCenter.default.addObserver(self, selector: #selector(systemLocked),
      name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  @objc private func systemLocked() { privacy?.invokeMethod("systemLocked", arguments: nil) }
  override func applicationWillResignActive(_ application: UIApplication) {
    if let window = window, cover == nil {
      let view = UIView(frame: window.bounds)
      view.backgroundColor = .systemBackground
      view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      let label = UILabel(frame: view.bounds)
      label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      label.text = "Six Tick"; label.textAlignment = .center
      label.font = .systemFont(ofSize: 28, weight: .semibold)
      view.addSubview(label); window.addSubview(view); cover = view
    }
    super.applicationWillResignActive(application)
  }
  override func applicationDidBecomeActive(_ application: UIApplication) {
    cover?.removeFromSuperview(); cover = nil
    super.applicationDidBecomeActive(application)
  }
}
