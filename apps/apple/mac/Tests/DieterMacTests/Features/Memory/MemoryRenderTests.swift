import AppKit
import DieterAPI
import DieterClientAPI
import SwiftUI
import Testing

@testable import DieterMacKit

/// Settings › Agent memory lays out its form, a dream conversation's banner
/// every state of the core's dream, and a project's settings its memory.
/// Set DIETER_MEMORY_SCREENSHOT_DIR to keep the PNGs.
@MainActor
struct MemoryRenderTests {
    static let staged = ClientMemoryDreamState.with {
        $0.cardID = "c_dream"
        $0.status = "staged"
        $0.title = "Dream awaiting review"
        $0.countsLabel = "2 added · 1 merged · 3 verified"
        $0.detail = "Apply the changes or discard them."
        $0.canApply = true
        $0.canDiscard = true
    }

    static let applied = ClientMemoryDreamState.with {
        $0.cardID = "c_dream"
        $0.status = "applied"
        $0.title = "Dream applied"
        $0.countsLabel = "2 added · 1 merged"
        $0.detail = "Undo restores the memories it changed."
        $0.canUndo = true
    }

    static let failed = ClientMemoryDreamState.with {
        $0.cardID = "c_dream"
        $0.status = "failed"
        $0.title = "Dream failed"
        $0.error = "Claude Code is not signed in on box."
    }

    static let running = ClientMemoryDreamState.with {
        $0.cardID = "c_dream"
        $0.status = "running"
        $0.running = true
        $0.title = "Dreaming…"
    }

    /// Lays `content` out in a window and returns its fitting size; with
    /// DIETER_MEMORY_SCREENSHOT_DIR set, also writes it as a PNG. The SwiftUI
    /// renderer draws text and shapes; AppKit views (pickers, steppers, text
    /// fields) show as placeholders there.
    private func render<Content: View>(_ content: Content, width: CGFloat, name: String) throws -> NSSize {
        let styled = content.frame(width: width)
            .padding(16)
            .background(Color(red: 0.055, green: 0.061, blue: 0.075))
            .foregroundStyle(DieterTheme.text)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: styled)
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        if let directory = ProcessInfo.processInfo.environment["DIETER_MEMORY_SCREENSHOT_DIR"] {
            let renderer = ImageRenderer(content: styled)
            renderer.scale = 2
            if let image = renderer.cgImage {
                let url = URL(fileURLWithPath: directory).appending(path: "\(name).png")
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: url, options: .atomic)
            }
        }
        return size
    }

    private func installTheme() {
        DieterTheme.install(
            selection: DieterThemeSelection(appearance: .dark, palette: .electricBlue, transparencyEnabled: false),
            systemColorScheme: .dark, reduceTransparency: true)
    }

    @Test func theDreamBannerLaysOutEveryState() throws {
        installTheme()
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }
        let staged = try render(
            MemoryDreamBanner(dream: Self.staged) { _ in }, width: 640, name: "macos-memory-dream-staged")
        let applied = try render(
            MemoryDreamBanner(dream: Self.applied) { _ in }, width: 640, name: "macos-memory-dream-applied")
        let failed = try render(
            MemoryDreamBanner(dream: Self.failed) { _ in }, width: 640, name: "macos-memory-dream-failed")
        let running = try render(
            MemoryDreamBanner(dream: Self.running) { _ in }, width: 640, name: "macos-memory-dream-running")
        #expect(running.height > 30 && running.height < 90, "a running dream is one compact line")
        #expect(staged.height > running.height, "counts and what the actions do lay out")
        #expect(applied.height > running.height && failed.height > running.height)
        #expect(staged.height < 140, "the banner stays compact")
    }

    @Test func theMemorySettingsPageLaysOutTheForm() async throws {
        installTheme()
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }
        let store = DieterStore(liveEnvironment: false)
        let core = MemoryModelTests.scriptedCore(MemoryModelTests.settings(configured: false))
        store.memoryModel.core = core
        store.foldMetadata(
            .with {
                $0.machines = [
                    "here": .with {
                        $0.loaded = true
                        $0.harnesses = MemoryModelTests.catalog
                    }
                ]
            })
        await store.memoryModel.load(daemonID: "here")
        #expect(store.memoryModel.draft != nil)
        // The page scrolls, which the SwiftUI renderer leaves blank; its
        // panels show as they lay out there.
        let form = try render(
            MemorySettingsForm(machine: "here").environment(store), width: 760, name: "macos-memory-settings")
        #expect(form.height > 600)
        store.memoryModel.draft?.window = "late"
        let invalid = try render(
            MemorySettingsForm(machine: "here").environment(store), width: 760,
            name: "macos-memory-settings-invalid")
        #expect(invalid.height >= form.height, "the window's problem shows under it and by Save")
        #expect(store.memoryModel.draftProblem != nil && !store.memoryModel.canSave)
        // The page reads the setting from the machine the core picks; this
        // store lists none, so the form says so.
        let page = try render(
            MemorySettings().environment(store).frame(height: 900), width: 760, name: "macos-memory-page")
        #expect(page.height >= 900)
    }

    @Test func aProjectsSettingsShowItsMemoryAndADreamStartedThere() async throws {
        installTheme()
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }
        let store = DieterStore(liveEnvironment: false)
        let core = ScriptedCoreClient()
        core.handler = { command in
            switch command.memory.action {
            case .startDream?:
                return .with { $0.memoryDream = MemoryRenderTests.running }
            default:
                return .with {
                    $0.memoryStatus = .with {
                        $0.machine = "Studio"
                        $0.projects = [
                            .with {
                                $0.projectID = "p_one"
                                $0.cards = 12
                                $0.saved = 5
                            }
                        ]
                    }
                }
            }
        }
        store.memoryModel.core = core
        let off = try render(
            Form {
                ProjectMemorySection(projectID: "p_one", enabled: false, draft: .constant(false), openDream: { _ in })
            }
            .formStyle(.grouped).environment(store), width: 600, name: "macos-project-memory-off")
        #expect(off.height > 60)
        #expect(core.commands.isEmpty, "a project without memory reads no state")
        await store.memoryModel.loadProject("p_one")
        await store.memoryModel.startDream("p_one")
        let on = try render(
            Form {
                ProjectMemorySection(projectID: "p_one", enabled: true, draft: .constant(true), openDream: { _ in })
            }
            .formStyle(.grouped).environment(store), width: 600, name: "macos-project-memory-on")
        #expect(on.height > off.height, "the state, Start a dream now and Open the dream lay out")
        // The grouped form scrolls, which the SwiftUI renderer leaves blank;
        // the state shows as it lays out on its own.
        let status = try render(
            ProjectMemoryStatus(projectID: "p_one", openDream: { _ in }).environment(store), width: 560,
            name: "macos-project-memory-status")
        #expect(status.height > 60)
    }
}
