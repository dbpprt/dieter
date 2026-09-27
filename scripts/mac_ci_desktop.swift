import CoreGraphics
import Foundation

// Hosted macOS runners boot at 1024x768, smaller than the native smoke window.
// Keep its controls and popover anchors on-screen. Change only the disposable
// runner's current login session.
let environment = ProcessInfo.processInfo.environment
guard environment["GITHUB_ACTIONS"] == "true",
  environment["RUNNER_ENVIRONMENT"] == "github-hosted"
else {
  fputs("Desktop configuration is restricted to GitHub-hosted runners.\n", stderr)
  exit(1)
}

let display = CGMainDisplayID()
func largeEnough(_ mode: CGDisplayMode) -> Bool {
  mode.width >= 1440 && mode.height >= 960 && mode.isUsableForDesktopGUI()
}
guard let current = CGDisplayCopyDisplayMode(display) else {
  fputs("The hosted runner has no active desktop.\n", stderr)
  exit(1)
}
print("Hosted desktop: \(current.width)x\(current.height)")
if !largeEnough(current) {
  let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
  let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
  guard
    let selected = modes.filter(largeEnough).min(by: {
      ($0.width * $0.height, $0.pixelWidth * $0.pixelHeight)
        < ($1.width * $1.height, $1.pixelWidth * $1.pixelHeight)
    })
  else {
    let available = modes.map { "\($0.width)x\($0.height)" }.joined(separator: ", ")
    fputs("No desktop mode can contain the native smoke window. Available: \(available)\n", stderr)
    exit(1)
  }
  var configuration: CGDisplayConfigRef?
  guard CGBeginDisplayConfiguration(&configuration) == .success else { exit(1) }
  guard CGConfigureDisplayWithDisplayMode(configuration, display, selected, nil) == .success else {
    CGCancelDisplayConfiguration(configuration)
    exit(1)
  }
  guard CGCompleteDisplayConfiguration(configuration, .forSession) == .success else { exit(1) }
}
guard let configured = CGDisplayCopyDisplayMode(display), largeEnough(configured) else {
  fputs("The hosted desktop did not accept the required mode.\n", stderr)
  exit(1)
}
print("Native smoke desktop: \(configured.width)x\(configured.height)")
