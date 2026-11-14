// The macOS app target of Dieter.xcodeproj: Xcode builds, embeds and signs the
// DieterMacKit package product (WebRTC.framework, resource bundles) around it.
import DieterMacKit

@main
enum DieterApp {
    @MainActor static func main() {
        DieterMacApp.main()
    }
}
