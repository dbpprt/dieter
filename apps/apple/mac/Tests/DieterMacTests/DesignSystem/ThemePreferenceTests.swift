import Foundation
import Observation
import SwiftUI
import Testing
@testable import DieterMacKit

/// Stored appearance and palette preferences and live theme selection.
struct ThemePreferenceTests {
    @Test func appearancePreferenceDefaultsToSystemAndRecognizesEveryStoredMode() {
        #expect(DieterAppearance.resolve(nil) == .system)
        #expect(DieterAppearance.resolve("unknown") == .system)
        #expect(DieterAppearance.allCases.map(\.rawValue) == ["system", "light", "dark"])
        #expect(DieterAppearance.resolve("system").colorScheme == nil)
        #expect(DieterAppearance.resolve("light").colorScheme == .light)
        #expect(DieterAppearance.resolve("dark").colorScheme == .dark)
    }

    @Test func palettePreferenceRecognizesEveryDesignAndDefaultsToMonochrome() {
        #expect(DieterPalette.resolve(nil) == .monochrome)
        #expect(DieterPalette.resolve("unknown") == .monochrome)
        #expect(DieterPalette.resolve("acid-terminal") == .monochrome)
        #expect(
            DieterPalette.allCases.map(\.rawValue) == [
                "monochrome",
                "electric-blue", "jade-operator", "copper-circuit", "ultraviolet-relay",
                "solar-command", "arctic-console", "coral-signal",
            ])
        #expect(Set(DieterPalette.allCases.map(\.title)).count == 8)
        #expect(DieterPalette.allCases.allSatisfy { DieterPalette.resolve($0.rawValue) == $0 })
    }

    @Test @MainActor func liveThemeSelectionInvalidatesObserversAndPersistsImmediately() async throws {
        let suiteName = "DieterMacTests.theme.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(DieterAppearance.light.rawValue, forKey: DieterAppearance.storageKey)
        defaults.set(DieterPalette.monochrome.rawValue, forKey: DieterPalette.storageKey)
        let store = DieterStore(themeDefaultsOverride: defaults, liveEnvironment: false)
        let (changes, continuation) = AsyncStream<Void>.makeStream()

        withObservationTracking {
            _ = store.themeSelection.identity
        } onChange: {
            continuation.yield()
        }
        store.themeSelection = DieterThemeSelection(
            appearance: .dark,
            palette: .coralSignal
        )

        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        continuation.finish()
        #expect(store.themeSelection.identity == "dark:coral-signal:glass")
        #expect(defaults.string(forKey: DieterAppearance.storageKey) == "dark")
        #expect(defaults.string(forKey: DieterPalette.storageKey) == "coral-signal")
        #expect(DieterThemeSelection.load(from: defaults) == store.themeSelection)
    }
}
