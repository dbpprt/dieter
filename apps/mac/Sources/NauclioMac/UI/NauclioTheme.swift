import AppKit
import SwiftUI

enum NauclioAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "NauclioAppearance"
    static let defaultsSuiteFlag = "--appearance-defaults-suite"
    static let defaultValue = NauclioAppearance.dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon.stars"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static func resolve(_ storedValue: String?) -> NauclioAppearance {
        storedValue.flatMap(Self.init(rawValue:)) ?? defaultValue
    }

    static func applicationDefaults(arguments: [String] = ProcessInfo.processInfo.arguments) -> UserDefaults {
        guard let flag = arguments.firstIndex(of: defaultsSuiteFlag),
              arguments.indices.contains(flag + 1),
              let defaults = UserDefaults(suiteName: arguments[flag + 1]) else { return .standard }
        return defaults
    }
}

private extension NSColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255,
            alpha: alpha
        )
    }
}

private extension Color {
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        let name = NSColor.Name("Nauclio.\(light).\(dark).\(lightAlpha).\(darkAlpha)")
        self.init(nsColor: NSColor(name: name) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua
                ? NSColor(rgb: dark, alpha: darkAlpha)
                : NSColor(rgb: light, alpha: lightAlpha)
        })
    }
}

/// Adaptive neutral surfaces with Nauclio's cobalt, Aegean, and seafoam brand
/// accents. Each semantic color preserves the visual hierarchy and accessible
/// contrast in both Aqua and Dark Aqua appearances.
enum NauclioTheme {
    static let background = Color(light: 0xF8F8FB, dark: 0x0C0C10)
    static let sidebar = Color(light: 0xF0F0F5, dark: 0x111116)
    static let surface = Color(light: 0xFFFFFF, dark: 0x17171E)
    static let raised = Color(light: 0xF3F3F7, dark: 0x1E1E27)
    static let elevated = Color(light: 0xE7E7EF, dark: 0x272733)
    static let input = Color(light: 0xFFFFFF, dark: 0x0A0A0E)
    static let border = Color(light: 0x16161C, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.07)
    static let strongBorder = Color(light: 0x16161C, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.13)
    static let text = Color(light: 0x1B1B21, dark: 0xF4F4F7)
    static let subtle = Color(light: 0x595A66, dark: 0xA6A6B4)
    static let tertiary = Color(light: 0x767783, dark: 0x6F6F7C)
    static let cobalt = Color(light: 0x1D4ED8, dark: 0x2563EB)
    static let aegean = Color(light: 0x087F9D, dark: 0x22D3EE)
    static let primary = Color(light: 0x1D4ED8, dark: 0x2563EB)
    static let seafoam = Color(light: 0x08766E, dark: 0x5EEAD4)
    static let amber = Color(light: 0xA84C08, dark: 0xE8A33D)
    static let coral = Color(light: 0xD52D4B, dark: 0xF26D80)

    /// Background for the selected navigation or list row.
    static let selection = Color(light: 0x1D4ED8, dark: 0x2563EB, lightAlpha: 0.13, darkAlpha: 0.22)
}

enum NauclioMetrics {
    static let browserWidth: CGFloat = 320
    static let browserMaximumWidth: CGFloat = 340
    static let sidebarExpandedWidth: CGFloat = 224
    static let sidebarCollapsedWidth: CGFloat = 58
    static let navigationRowHeight: CGFloat = 32
    static let controlRadius: CGFloat = 8
    static let cardRadius: CGFloat = 10
}

/// Shared type scale so every pane uses the same few text styles.
enum NauclioFont {
    /// Prominent pane titles ("Chats", "Files", board name).
    static let paneTitle = Font.system(size: 16, weight: .semibold)
    /// Titles of secondary headers (conversation title, detail panes).
    static let title = Font.system(size: 13, weight: .semibold)
    /// Metadata line under a title.
    static let subtitle = Font.system(size: 11)
    /// Uppercased section labels (PROJECTS, MACHINES, …).
    static let sectionLabel = Font.system(size: 10, weight: .semibold)
    /// Standard interactive rows and body copy.
    static let body = Font.system(size: 13)
    /// Secondary row text and compact controls.
    static let control = Font.system(size: 12, weight: .medium)
    /// Small supporting metadata.
    static let meta = Font.system(size: 11)
}

struct FluidPaneChrome<Primary: View, Secondary: View>: View {
    let background: Color
    let spacing: CGFloat
    private let hasSecondary: Bool
    let primary: Primary
    let secondary: Secondary

    init(
        background: Color = NauclioTheme.sidebar,
        spacing: CGFloat = 10,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder secondary: () -> Secondary
    ) {
        self.background = background
        self.spacing = spacing
        hasSecondary = true
        self.primary = primary()
        self.secondary = secondary()
    }

    init(
        background: Color = NauclioTheme.sidebar,
        @ViewBuilder primary: () -> Primary
    ) where Secondary == EmptyView {
        self.background = background
        spacing = 0
        hasSecondary = false
        self.primary = primary()
        secondary = EmptyView()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: hasSecondary ? spacing : 0) {
            primary.frame(maxWidth: .infinity, alignment: .leading)
            if hasSecondary { secondary.frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }
}

struct PaneTitleBlock: View {
    let title: String
    var subtitle: String = ""
    var symbol: String? = nil
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(prominent ? NauclioFont.paneTitle : NauclioFont.title)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(NauclioFont.subtitle)
                    .foregroundStyle(NauclioTheme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

struct NauclioFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 7
    var verticalSpacing: CGFloat = 7

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let maximumWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextX = x == 0 ? 0 : x + horizontalSpacing
            if x > 0, nextX + size.width > maximumWidth {
                y += rowHeight + verticalSpacing
                x = size.width
                rowHeight = size.height
            } else {
                x = nextX + size.width
                rowHeight = max(rowHeight, size.height)
            }
            usedWidth = max(usedWidth, x)
        }

        return CGSize(width: min(usedWidth, maximumWidth), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextX = x == bounds.minX ? x : x + horizontalSpacing
            if x > bounds.minX, nextX + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            } else {
                x = nextX
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct SurfaceModifier: ViewModifier {
    var radius: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .background(NauclioTheme.surface.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(NauclioTheme.border))
    }
}

extension View {
    func nauclioSurface(radius: CGFloat = 12) -> some View { modifier(SurfaceModifier(radius: radius)) }
}

struct StatusPill: View {
    let text: String
    var color: Color = NauclioTheme.subtle

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label).lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
    }

    private var label: String {
        let value = text.isEmpty ? "idle" : text
        return value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// A compact, continuously rotating activity arc for rows whose agent is
/// currently working. Timeline-driven rotation stays alive when list rows are
/// reused or rebuilt during state synchronization.
struct NauclioActivityIndicator: View {
    var color: Color = NauclioTheme.primary
    var size: CGFloat = 11
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.35), lineWidth: 1.5)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
                Circle()
                    .trim(from: 0.08, to: 0.72)
                    .stroke(color, style: .init(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(rotation(at: context.date))
            }
        }
        .frame(width: size, height: size)
    }

    private func rotation(at date: Date) -> Angle {
        guard !reduceMotion else { return .zero }
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
        return .degrees(progress * 360)
    }
}

struct NauclioIconButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(active ? NauclioTheme.text : NauclioTheme.subtle)
            .frame(width: 30, height: 28)
            .background(
                active ? NauclioTheme.elevated : (configuration.isPressed ? NauclioTheme.raised : NauclioTheme.surface),
                in: RoundedRectangle(cornerRadius: NauclioMetrics.controlRadius, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct NauclioPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13).frame(height: 30)
            .background(NauclioTheme.cobalt, in: RoundedRectangle(cornerRadius: NauclioMetrics.controlRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct NauclioSecondaryButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(destructive ? NauclioTheme.coral : NauclioTheme.subtle)
            .padding(.horizontal, 12).frame(height: 30)
            .background(NauclioTheme.surface.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: NauclioMetrics.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NauclioMetrics.controlRadius, style: .continuous).stroke(NauclioTheme.border))
    }
}

struct NauclioChipLabel: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = NauclioTheme.subtle
    var maximumTitleWidth: CGFloat? = nil
    var showsDisclosure = true

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: maximumTitleWidth, alignment: .leading)
            if showsDisclosure {
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.6)
            }
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
        .padding(.horizontal, 9).frame(height: 28)
        .background(NauclioTheme.surface, in: RoundedRectangle(cornerRadius: NauclioMetrics.controlRadius, style: .continuous))
    }
}

struct NauclioSearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(NauclioTheme.tertiary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(NauclioTheme.tertiary)
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(NauclioTheme.surface, in: RoundedRectangle(cornerRadius: NauclioMetrics.controlRadius, style: .continuous))
    }
}

func runtimeColor(_ runtime: String) -> Color {
    switch runtime.lowercased() {
    case "running", "active", "working", "starting": NauclioTheme.primary
    case "review", "waiting", "needs_input", "waiting_for_user": NauclioTheme.amber
    case "completed", "done": NauclioTheme.seafoam
    case "idle": NauclioTheme.subtle
    case "failed", "error", "cancelled": NauclioTheme.coral
    default: NauclioTheme.subtle
    }
}
