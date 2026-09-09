import AppKit
import Observation
import SwiftUI

/// One source for System mode. Window/hosting-view appearance can be provisional
/// during launch, and explicit Light/Dark windows must not feed back into it.
@MainActor @Observable
final class DieterSystemAppearance {
    static let shared = DieterSystemAppearance()
    private(set) var colorScheme: ColorScheme
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var themeObserver: NSObjectProtocol?

    static func resolve(interfaceStyle: String?) -> ColorScheme {
        interfaceStyle?.lowercased() == "dark" ? .dark : .light
    }

    private static func read() -> ColorScheme {
        // Read the global domain, independent of Dieter's own selected mode or
        // an AppKit appearance override from an auxiliary window.
        resolve(
            interfaceStyle: UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[
                "AppleInterfaceStyle"] as? String)
    }

    private init() {
        colorScheme = Self.read()
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) {
            [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        for name in [NSApplication.didFinishLaunchingNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                })
        }
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() { colorScheme = Self.read() }
}
