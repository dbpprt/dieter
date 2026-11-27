import AppKit
import DieterAPI
import DieterClientAPI
import SwiftUI
import Testing

@testable import DieterMacKit

/// The review card lays out every state of the core's review, the transcript
/// routes CODE_REVIEW steps to it, and Settings › Code reviewer lays out its
/// form. Set DIETER_CODE_REVIEW_SCREENSHOT_DIR to keep the PNGs.
@MainActor
struct CodeReviewRenderTests {
    static func finding(
        _ id: String, severity: String, title: String, status: String = "new", body: String = "",
        suggestion: String = ""
    ) -> ClientTimelineCodeReviewFinding {
        .with {
            $0.id = id
            $0.file = "internal/git/unborn.go"
            $0.startLine = 23
            $0.endLine = 26
            $0.locationLabel = "internal/git/unborn.go:23–26"
            $0.severity = severity
            $0.severityLabel = severity.prefix(1).uppercased() + severity.dropFirst()
            $0.confidence = 8
            $0.title = title
            $0.body = body
            $0.suggestion = suggestion
            $0.status = status
            $0.statusLabel = status == "open" ? "Still open" : status == "resolved" ? "Resolved" : "New"
        }
    }

    static let completed = ClientTimelineCodeReview.with {
        $0.reviewID = "rev_2"
        $0.cardID = "c_card"
        $0.status = "completed"
        $0.title = "Code review"
        $0.subtitle = "Claude Code · opus · quick · 42 s · 224k tokens"
        $0.countsLabel = "3 findings · 1 high"
        $0.changeLabel = "12 files · +340 −41"
        $0.roundLabel = "Round 2 · 1 resolved · 1 still open · 2 new"
        $0.triggerLabel = "Requested by the agent"
        $0.summary = "Adds unborn-branch handling to the Git status reader and its tests."
        $0.security = "The new path joins user input into a shell command."
        $0.highestSeverity = "high"
        $0.findings = [
            finding(
                "f1", severity: "high", title: "An unborn HEAD reads as a detached checkout",
                body: "`git rev-parse HEAD` fails before the first commit.",
                suggestion: "Check `symbolic-ref` first."),
            finding("f2", severity: "medium", title: "The retry loop never backs off", status: "open"),
            finding("f3", severity: "low", title: "A comment still names the old helper"),
        ]
        $0.resolved = [finding("f0", severity: "medium", title: "Errors were swallowed", status: "resolved")]
    }

    static let running = ClientTimelineCodeReview.with {
        $0.reviewID = "rev_3"
        $0.status = "running"
        $0.running = true
        $0.title = "Reviewing changes…"
        $0.subtitle = "Claude Code · opus · quick"
        $0.triggerLabel = "Requested by you"
    }

    static let failed = ClientTimelineCodeReview.with {
        $0.reviewID = "rev_4"
        $0.status = "failed"
        $0.title = "Code review failed"
        $0.error = "The reviewer could not start: Claude Code is not signed in on box."
    }

    /// Lays `content` out in a window and returns its fitting size; with
    /// DIETER_CODE_REVIEW_SCREENSHOT_DIR set, also writes it as a PNG. The
    /// SwiftUI renderer draws text and shapes; AppKit views (the Markdown
    /// text, pickers, steppers) show as placeholders there.
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
        if let directory = ProcessInfo.processInfo.environment["DIETER_CODE_REVIEW_SCREENSHOT_DIR"] {
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

    @Test func theReviewCardLaysOutEveryState() throws {
        installTheme()
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }
        let completed = try render(CodeReviewCard(review: Self.completed), width: 640, name: "macos-code-review")
        let running = try render(CodeReviewCard(review: Self.running), width: 640, name: "macos-code-review-running")
        let failed = try render(CodeReviewCard(review: Self.failed), width: 640, name: "macos-code-review-failed")
        #expect(running.height > 40 && failed.height > 40)
        #expect(completed.height > max(running.height, failed.height) + 100, "findings and the resolved row lay out")
        let empty = try render(
            CodeReviewCard(
                review: .with {
                    $0.reviewID = "rev_5"; $0.title = "Code review"; $0.countsLabel = "No changes to review"
                }), width: 640, name: "macos-code-review-empty")
        #expect(empty.height > 40)
        let row = try render(
            CodeReviewFindingRow(reviewID: "rev_2", finding: Self.completed.findings[0], openLocation: { _ in }),
            width: 600, name: "macos-code-review-finding")
        #expect(row.height > 20)
    }

    @Test func theTranscriptShowsCodeReviewStepsAsTheirCard() throws {
        installTheme()
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }
        let step = ClientTimelineStep.with {
            $0.id = "step"
            $0.kind = .codeReview
            $0.codeReview = Self.completed
        }
        let shown = try render(
            TimelineStepView(step: step, part: nil, inUserBubble: false), width: 640, name: "macos-code-review-step")
        let card = try render(CodeReviewCard(review: Self.completed), width: 640, name: "macos-code-review-card")
        #expect(shown == card, "the step is the card, without its message part")
        var bare = step
        bare.clearCodeReview()
        let nothing = try render(
            TimelineStepView(step: bare, part: nil, inUserBubble: false), width: 640, name: "macos-code-review-bare")
        #expect(nothing.height < 40, "a step without its review shows nothing")
    }

    @Test func theCodeReviewerSettingsPageLaysOutTheForm() async throws {
        installTheme()
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }
        let store = DieterStore(liveEnvironment: false)
        let core = ScriptedCoreClient()
        let settings = CodeReviewModelTests.settings(configured: false)
        core.handler = { _ in .with { $0.reviewerSettings = settings } }
        store.codeReviewerModel.core = core
        store.foldMetadata(
            .with {
                $0.machines = [
                    "here": .with {
                        $0.loaded = true
                        $0.harnesses = CodeReviewModelTests.catalog
                    }
                ]
            })
        await store.codeReviewerModel.load(daemonID: "here")
        #expect(store.codeReviewerModel.draft != nil)
        // The page scrolls, which the SwiftUI renderer leaves blank; its
        // panels show as they lay out there.
        let form = try render(
            CodeReviewerSettingsForm(machine: "here").environment(store), width: 760,
            name: "macos-code-reviewer-settings")
        #expect(form.height > 400)
        store.codeReviewerModel.draft?.maxRounds = 12
        let invalid = try render(
            CodeReviewerSettingsForm(machine: "here").environment(store), width: 760,
            name: "macos-code-reviewer-settings-invalid")
        #expect(invalid.height > 400)
        #expect(store.codeReviewerModel.draftProblem != nil && !store.codeReviewerModel.canSave)
        // The page reads the setting from the machine the core picks; this
        // store lists none, so the form says so.
        let page = try render(
            CodeReviewerSettings().environment(store).frame(height: 900), width: 760,
            name: "macos-code-reviewer-page")
        #expect(page.height >= 900)
    }
}
