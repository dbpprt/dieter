import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func systemAppearanceResolvesGlobalMacPreference() {
    #expect(DieterSystemAppearance.resolve(interfaceStyle: "Dark") == .dark)
    #expect(DieterSystemAppearance.resolve(interfaceStyle: nil) == .light)
    #expect(DieterSystemAppearance.resolve(interfaceStyle: "Light") == .light)
}

@Test @MainActor func systemThemeDoesNotReuseLastWindowOverride() {
    let system = DieterSystemAppearance.shared.colorScheme
    DieterTheme.install(palette: .monochrome, colorScheme: system == .dark ? .light : .dark)
    DieterTheme.install(selection: .init(appearance: .system, palette: .monochrome))
    let actual = NSColor(DieterTheme.background).usingColorSpace(.deviceRGB)!
    DieterTheme.install(palette: .monochrome, colorScheme: system)
    let expected = NSColor(DieterTheme.background).usingColorSpace(.deviceRGB)!
    #expect(abs(actual.redComponent - expected.redComponent) < 0.001)
}
