// Run the packaged executable on an Intel runner and require an actual window.
import AppKit
import CoreGraphics
import Foundation

let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let info = try PropertyListSerialization.propertyList(
    from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
    format: nil
) as! [String: Any]
let executable = info["CFBundleExecutable"] as! String
let process = Process()
process.executableURL = app.appendingPathComponent("Contents/MacOS/" + executable)
try process.run()
defer {
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
    }
}

var windowSeen = false
for _ in 0..<20 {
    Thread.sleep(forTimeInterval: 1)
    guard process.isRunning else {
        fatalError("App exited during startup: \(process.terminationStatus)")
    }
    let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    windowSeen = windows.contains { window in
        guard let pid = window[kCGWindowOwnerPID as String] as? Int,
              let layer = window[kCGWindowLayer as String] as? Int,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double else { return false }
        return pid == Int(process.processIdentifier) && layer == 0 && width >= 400 && height >= 500
    }
    if windowSeen { break }
}
guard windowSeen else { fatalError("App did not create its main window within 20 seconds") }
Thread.sleep(forTimeInterval: 5)
guard process.isRunning else { fatalError("App exited after opening its window") }
print("::notice title=Intel launch smoke test::Application launched on Intel and created its main window.")
