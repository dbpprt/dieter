import AppKit
import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import DieterMac

@Suite(.serialized)
struct DieterTransparencyTests {
    @Test func missingPreferenceUsesGlassAndExplicitOffSurvivesReload() throws {
        let suite = "DieterTransparencyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(DieterTransparency.defaultEnabled)
        #expect(DieterTransparency.load(from: defaults))
        #expect(DieterThemeSelection.load(from: defaults).transparencyEnabled)

        var selection = DieterThemeSelection(appearance: .dark, palette: .jadeOperator)
        selection.transparencyEnabled = false
        selection.save(to: defaults)

        #expect(defaults.object(forKey: DieterTransparency.storageKey) != nil)
        #expect(!DieterTransparency.load(from: defaults))
        #expect(DieterThemeSelection.load(from: defaults) == selection)
        #expect(selection.identity == "dark:jade-operator:solid")

        selection.transparencyEnabled = true
        selection.save(to: defaults)
        #expect(DieterThemeSelection.load(from: defaults) == selection)
        #expect(selection.identity == "dark:jade-operator:glass")
    }

    @Test @MainActor func changingOnlyTransparencyInvalidatesObserversAndPersists() throws {
        let suite = "DieterTransparencyTests.store.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DieterStore(themeDefaultsOverride: defaults, restoreSync: false)
        let original = store.themeSelection
        let observedChange = Mutex(false)
        withObservationTracking {
            _ = store.themeSelection.identity
        } onChange: {
            observedChange.withLock { $0 = true }
        }

        store.themeSelection.transparencyEnabled = false

        #expect(observedChange.withLock { $0 })
        #expect(store.themeSelection.identity != original.identity)
        #expect(store.themeSelection.appearance == original.appearance)
        #expect(store.themeSelection.palette == original.palette)
        #expect(!defaults.bool(forKey: DieterTransparency.storageKey))
        #expect(DieterThemeSelection.load(from: defaults) == store.themeSelection)
    }

    @Test @MainActor func changingTransparencyUpdatesExistingThemeConsumers() {
        defer { DieterTheme.install(selection: .load()) }
        var selection = DieterThemeSelection(appearance: .dark, palette: .monochrome)
        DieterTheme.install(selection: selection, reduceTransparency: false)
        let observedChange = Mutex(false)
        withObservationTracking {
            _ = DieterTheme.usesTransparency
            _ = DieterTheme.background
        } onChange: {
            observedChange.withLock { $0 = true }
        }

        selection.transparencyEnabled = false
        DieterTheme.install(selection: selection, reduceTransparency: false)

        #expect(observedChange.withLock { $0 })
        #expect(!DieterTheme.usesTransparency)
        #expect(NSColor(DieterTheme.background).alphaComponent == 1)
    }

    @Test @MainActor func accessibilityTemporarilyOverridesGlassWithoutChangingSavedChoice() throws {
        let suite = "DieterTransparencyTests.accessibility.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            DieterTheme.install(selection: .load())
        }
        let selection = DieterThemeSelection(appearance: .dark, palette: .coralSignal)
        selection.save(to: defaults)

        DieterTheme.install(selection: selection, reduceTransparency: false)
        #expect(DieterTheme.usesTransparency)
        DieterTheme.install(selection: selection, reduceTransparency: true)
        #expect(!DieterTheme.usesTransparency)
        #expect(NSColor(DieterTheme.background).alphaComponent == 1)
        #expect(DieterThemeSelection.load(from: defaults).transparencyEnabled)
        DieterTheme.install(selection: selection, reduceTransparency: false)
        #expect(DieterTheme.usesTransparency)

        var solid = selection
        solid.transparencyEnabled = false
        DieterTheme.install(selection: solid, reduceTransparency: false)
        #expect(!DieterTheme.usesTransparency)
    }

    @Test @MainActor func everyPaletteKeepsOpaqueFallbacksAndReadableTerminalBackgrounds() {
        defer { DieterTheme.install(selection: .load()) }
        for palette in DieterPalette.allCases {
            for appearance in [DieterAppearance.light, .dark] {
                var selection = DieterThemeSelection(appearance: appearance, palette: palette)
                DieterTheme.install(selection: selection, reduceTransparency: false)
                #expect(DieterTheme.usesTransparency)
                #expect(NSColor(DieterTheme.opaqueSurface).alphaComponent == 1)
                #expect(DieterTheme.terminalBackgroundColor.alphaComponent == 1)
                #expect(NSColor(DieterTheme.terminalBackground).alphaComponent == 1)

                selection.transparencyEnabled = false
                DieterTheme.install(selection: selection, reduceTransparency: false)
                #expect(!DieterTheme.usesTransparency)
                #expect(NSColor(DieterTheme.background).alphaComponent == 1)
                #expect(NSColor(DieterTheme.opaqueSurface).alphaComponent == 1)
                #expect(DieterTheme.terminalBackgroundColor.alphaComponent == 1)
            }
        }
    }

    @Test @MainActor func nativeBackdropChangesTheSameWindowWithoutReplacingItsEditor() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let originalOpaque = window.isOpaque
        let originalBackground = window.backgroundColor
        let originalTitlebar = window.titlebarAppearsTransparent
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        let backdrop = DieterWindowBackdropView(frame: content.bounds)
        let editor = NSTextView(frame: NSRect(x: 20, y: 20, width: 300, height: 200))
        editor.string = "Keep this selection while changing glass."
        let selection = NSRange(location: 5, length: 14)
        let fallback = NSColor(srgbRed: 0.15, green: 0.17, blue: 0.19, alpha: 1)

        // Configure before attachment: viewDidMoveToWindow must apply the mode.
        backdrop.configure(transparencyEnabled: true, solidColor: fallback)
        content.addSubview(backdrop)
        content.addSubview(editor)
        window.contentView = content
        window.makeFirstResponder(editor)
        editor.setSelectedRange(selection)

        #expect(!window.isOpaque)
        #expect(window.backgroundColor.alphaComponent == 0)
        #expect(window.titlebarAppearsTransparent)
        #expect(backdrop.blendingMode == .behindWindow)

        backdrop.configure(transparencyEnabled: false, solidColor: fallback)
        #expect(window.isOpaque)
        #expect(window.backgroundColor == fallback)
        #expect(window.contentView === content)
        #expect(window.firstResponder === editor)
        #expect(editor.selectedRange() == selection)

        backdrop.configure(transparencyEnabled: true, solidColor: fallback)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor.alphaComponent == 0)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.contentView === content)
        #expect(window.firstResponder === editor)
        #expect(editor.selectedRange() == selection)

        // A detached view can be configured for solid mode before it is reused.
        backdrop.removeFromSuperview()
        #expect(window.isOpaque == originalOpaque)
        #expect(window.backgroundColor == originalBackground)
        #expect(window.titlebarAppearsTransparent == originalTitlebar)
        backdrop.configure(transparencyEnabled: false, solidColor: fallback)
        content.addSubview(backdrop, positioned: .below, relativeTo: editor)
        #expect(window.isOpaque)
        #expect(window.backgroundColor == fallback)
        #expect(window.contentView === content)
    }
}
