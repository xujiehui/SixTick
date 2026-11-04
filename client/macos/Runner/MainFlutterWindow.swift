import Cocoa
import FlutterMacOS
import LocalAuthentication
import Security

class MainFlutterWindow: NSWindow {
  private var privacy: FlutterMethodChannel?
  private var cover: NSView?
  private var biometricKeys: BiometricKeyChannel?
  override func awakeFromNib() {
    let controller = FlutterViewController()
    let windowFrame = frame
    contentViewController = controller
    setFrame(windowFrame, display: true)
    title = "Six Tick"
    RegisterGeneratedPlugins(registry: controller)
    biometricKeys = BiometricKeyChannel(messenger: controller.engine.binaryMessenger)
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

/// Password vaults may opt into an additional, biometric-protected keychain key.
/// Keeping this bridge in the Runner source also includes it in every build config.
final class BiometricKeyChannel {
  private let channel: FlutterMethodChannel
  private let service = (Bundle.main.bundleIdentifier ?? "six_tick") + ".biometric-vault"
  private var authenticating = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "six_tick/biometric_key", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func query(_ id: String) -> [String: Any] {
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: id,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: false,
    ]
  }

  private func failure(_ code: String) -> FlutterError {
    return FlutterError(code: code, message: nil, details: nil)
  }

  private func keychainFailure(_ status: OSStatus) -> FlutterError {
    return failure(status == errSecMissingEntitlement
      ? "biometric_signing_required" : "biometric_key_unavailable")
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "available" {
      let context = LAContext()
      result(context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil))
      context.invalidate()
      return
    }
    guard ["write", "read", "delete"].contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let arguments = call.arguments as? [String: Any],
          let id = arguments["id"] as? String, !id.isEmpty, id.count <= 128 else {
      result(failure("biometric_key_unavailable"))
      return
    }
    let item = query(id)
    if call.method == "delete" {
      let status = SecItemDelete(item as CFDictionary)
      result(status == errSecSuccess || status == errSecItemNotFound
        ? nil : keychainFailure(status))
      return
    }
    guard !authenticating else {
      result(failure("authentication_cancelled"))
      return
    }
    let bytes = (arguments["key"] as? FlutterStandardTypedData)?.data
    if call.method == "write" && bytes?.count != 32 {
      result(failure("biometric_key_unavailable"))
      return
    }
    let context = LAContext()
    context.localizedFallbackTitle = ""
    context.touchIDAuthenticationAllowableReuseDuration = 0
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
      context.invalidate()
      result(failure("biometric_unavailable"))
      return
    }
    authenticating = true
    let reason = call.method == "write"
      ? "为 Six Tick 启用 Touch ID / Enable Touch ID for Six Tick"
      : "解锁 Six Tick / Unlock Six Tick"
    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) {
      success, _ in
      // Keychain operations may block; never run an authentication query on the UI thread.
      DispatchQueue.global(qos: .userInitiated).async {
        let response: Any?
        if !success {
          response = self.failure("authentication_cancelled")
        } else if call.method == "write" {
          if let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, nil
          ) {
            var attributes = item
            attributes[kSecAttrAccessControl as String] = access
            attributes[kSecValueData as String] = bytes!
            let status = SecItemAdd(attributes as CFDictionary, nil)
            response = status == errSecSuccess ? nil : self.keychainFailure(status)
          } else {
            response = self.failure("biometric_key_unavailable")
          }
        } else {
          var attributes = item
          attributes[kSecUseAuthenticationContext as String] = context
          attributes[kSecReturnData as String] = true
          attributes[kSecMatchLimit as String] = kSecMatchLimitOne
          var value: CFTypeRef?
          let status = SecItemCopyMatching(attributes as CFDictionary, &value)
          if status == errSecSuccess, let data = value as? Data, data.count == 32 {
            response = FlutterStandardTypedData(bytes: data)
          } else {
            response = self.keychainFailure(status)
          }
        }
        context.invalidate()
        DispatchQueue.main.async {
          self.authenticating = false
          result(response)
        }
      }
    }
  }
}
