import AppKit
import DieterClientAPI
import SwiftUI
import Testing

@testable import DieterMacKit

/// Settings › Providers and the sign-in sheet lay out every state of the
/// core's rows. Set DIETER_PROVIDERS_SCREENSHOT_DIR to keep the PNGs.
@MainActor
struct ProvidersRenderTests {
    private static func resetsAt(hours: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(hours * 3_600))
    }

    static func fixtureSlice() -> ClientProvidersSlice {
        let work = ClientProviderAccountRow.with {
            $0.id = "pa_work"
            $0.label = "Work"
            $0.identity = "alice@corp.com"
            $0.subtitle = "Max · Claude Code sign-in"
            $0.method = "claude-code"
            $0.isDefault = true
            $0.included = true
            $0.remaining = 62
            $0.severity = .normal
            $0.windows = [
                .with {
                    $0.id = "five_hour"; $0.name = "5 hour"; $0.remaining = 62; $0.severity = .normal
                    $0.resetsAt = resetsAt(hours: 2.5)
                },
                .with {
                    $0.id = "weekly"; $0.name = "Weekly"; $0.remaining = 88; $0.severity = .normal
                    $0.resetsAt = resetsAt(hours: 70)
                },
            ]
            $0.usageObservedAt = resetsAt(hours: -0.05)
            $0.dieterTokens = "1.2M tokens in 5 h · 8.4M in 7 days"
            $0.canSignInAll = true
            $0.machines = [
                .with {
                    $0.daemonID = "d_mini"; $0.name = "mini"; $0.online = true; $0.state = "signed_in"
                    $0.stateLabel = "Signed in"; $0.detail = "alice@corp.com · verified 2m ago"
                    $0.canSignOut = true; $0.canCheck = true
                },
                .with {
                    $0.daemonID = "d_box"; $0.name = "box"; $0.online = true; $0.state = "not_signed_in"
                    $0.stateLabel = "Not signed in"; $0.canSignIn = true
                },
            ]
        }
        let personal = ClientProviderAccountRow.with {
            $0.id = "pa_personal"
            $0.label = "Personal"
            $0.identity = "bob@home.com"
            $0.subtitle = "Plus · Codex sign-in"
            $0.method = "codex"
            $0.isDefault = true
            $0.included = false
            $0.remaining = 8
            $0.severity = .critical
            $0.windows = [
                .with {
                    $0.id = "five_hour"; $0.name = "5 hour"; $0.remaining = 8; $0.severity = .critical
                    $0.resetsAt = resetsAt(hours: 0.6)
                }
            ]
            $0.usageObservedAt = resetsAt(hours: -2)
            $0.canReset = true
            $0.resetLabel = "Reset usage limits (1 credit)"
            $0.manageUsageURL = "https://chatgpt.com/codex/settings/usage"
            $0.machines = [
                .with {
                    $0.daemonID = "d_mini"; $0.name = "mini"; $0.online = false; $0.state = "expired"
                    $0.stateLabel = "Sign-in expired"; $0.canSignIn = true
                }
            ]
        }
        return .with {
            $0.groups = [
                .with {
                    $0.provider = "claude"; $0.providerName = "Claude"; $0.summary = "1 account"
                    $0.defaultAccountID = "pa_work"; $0.accounts = [work]
                },
                .with {
                    $0.provider = "chatgpt"; $0.providerName = "ChatGPT"; $0.summary = "1 account · 1 excluded"
                    $0.defaultAccountID = "pa_personal"; $0.accounts = [personal]
                },
            ]
            $0.summary = .with {
                $0.text = "8% left"
                $0.severity = .critical
                $0.items = [
                    .with {
                        $0.provider = "claude"; $0.providerName = "Claude"; $0.remaining = 62
                        $0.severity = .normal; $0.text = "Claude 62% left"; $0.accountID = "pa_work"
                    }
                ]
            }
            $0.sessions = [
                .with {
                    $0.id = "signin_code"; $0.accountID = "pa_work"; $0.accountLabel = "Work"
                    $0.daemonID = "d_box"; $0.machine = "box"; $0.title = "Sign in to Claude Code on box"
                    $0.phase = "waiting"; $0.openURL = "https://claude.ai/oauth/authorize"; $0.expects = "code"
                    $0.instructions = "Paste the code Anthropic shows you"; $0.remainingMachines = 1
                },
                .with {
                    $0.id = "signin_device"; $0.accountID = "pa_personal"; $0.accountLabel = "Personal"
                    $0.daemonID = "d_mini"; $0.machine = "mini"; $0.title = "Sign in to Codex on mini"
                    $0.phase = "waiting"; $0.openURL = "https://auth.openai.com/codex/device"; $0.expects = "none"
                    $0.userCode = "ABCDEFGH"; $0.expiresAt = resetsAt(hours: 0.25)
                    $0.instructions = "Open the page and enter this code"
                },
                .with {
                    $0.id = "signin_done"; $0.accountID = "pa_work"; $0.accountLabel = "Work"
                    $0.daemonID = "d_box"; $0.machine = "box"; $0.title = "Sign in to Claude Code on box"
                    $0.phase = "succeeded"; $0.instructions = "Signed in as alice@corp.com on box"
                },
            ]
        }
    }

    /// Lays `content` out in a window and returns its fitting size; with
    /// DIETER_PROVIDERS_SCREENSHOT_DIR set, also writes it as a PNG. The
    /// SwiftUI renderer draws text, meters and shapes; AppKit controls show
    /// as placeholders there.
    private func render<Content: View>(_ content: Content, width: CGFloat, name: String) throws -> NSSize {
        let styled = content.frame(width: width)
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
        if let directory = ProcessInfo.processInfo.environment["DIETER_PROVIDERS_SCREENSHOT_DIR"] {
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

    @Test func providersPageAndSignInSheetLayOutEveryState() throws {
        DieterTheme.install(
            selection: DieterThemeSelection(appearance: .dark, palette: .electricBlue, transparencyEnabled: false),
            systemColorScheme: .dark, reduceTransparency: true)
        defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }
        let store = DieterStore(liveEnvironment: false)
        store.providersModel.install(Self.fixtureSlice())

        let page = try render(
            ProvidersSettings().environment(store).frame(height: 1_100), width: 760, name: "macos-providers")
        #expect(page.height >= 1_000)
        // The page scrolls, which the SwiftUI renderer leaves blank; its
        // account panels show as they lay out there.
        let slice = Self.fixtureSlice()
        let panels = try render(
            VStack(spacing: 12) {
                ForEach(slice.groups, id: \.provider) { group in
                    ForEach(group.accounts, id: \.id) { account in
                        ProviderAccountPanel(account: account, provider: group.provider)
                    }
                }
            }
            .padding(16)
            .environment(store),
            width: 760, name: "macos-provider-accounts")
        #expect(panels.height > 300)
        let sidebar = try render(
            ProviderSidebarBlock().environment(store).padding(8), width: 260, name: "macos-providers-sidebar")
        #expect(sidebar.height > 30)
        for id in ["signin_code", "signin_device", "signin_done", "signin_gone"] {
            let sheet = try render(
                ProviderSignInSheet(sessionID: id, replace: { _ in }, close: {}).environment(store),
                width: 500, name: "macos-\(id)")
            #expect(sheet.height > 100, "\(id) lays out")
        }
        let notice = try render(
            ProviderNoticeBanner(
                notice: .with {
                    $0.accountID = "pa_home"; $0.accountLabel = "Home"; $0.daemonID = "d_box"; $0.machine = "box"
                    $0.title = "Home isn't signed in on box"; $0.action = "sign_in"
                },
                accounts: [
                    .with {
                        $0.id = "pa_work"; $0.label = "Work"; $0.ready = true
                    }
                ],
                signIn: {}, chooseAccount: { _ in }),
            width: 640, name: "macos-provider-notice")
        #expect(notice.height > 40)
    }
}
