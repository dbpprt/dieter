import AppKit
import SwiftUI

enum DieterAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "DieterAppearance"
    static let defaultsSuiteFlag = "--appearance-defaults-suite"
    static let defaultValue = DieterAppearance.dark

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

    static func resolve(_ storedValue: String?) -> DieterAppearance {
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
        let name = NSColor.Name("Dieter.\(light).\(dark).\(lightAlpha).\(darkAlpha)")
        self.init(nsColor: NSColor(name: name) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua
                ? NSColor(rgb: dark, alpha: darkAlpha)
                : NSColor(rgb: light, alpha: lightAlpha)
        })
    }
}

/// Arctic Console surfaces and cold shell-blue accents, adapted for both Aqua
/// and Dark Aqua while retaining the palette's contrast hierarchy.
enum DieterTheme {
    static let background = Color(light: 0xF5FBFD, dark: 0x081116)
    static let sidebar = Color(light: 0xEAF6F8, dark: 0x0D1B24)
    static let surface = Color(light: 0xFFFFFF, dark: 0x122834)
    static let raised = Color(light: 0xEDF7F9, dark: 0x193A49)
    static let elevated = Color(light: 0xD7F2F5, dark: 0x234352)
    static let input = Color(light: 0xFFFFFF, dark: 0x071015)
    static let border = Color(light: 0x0D1B24, dark: 0xBCEAF1, lightAlpha: 0.10, darkAlpha: 0.09)
    static let strongBorder = Color(light: 0x0D1B24, dark: 0xBCEAF1, lightAlpha: 0.18, darkAlpha: 0.16)
    static let text = Color(light: 0x0D1B24, dark: 0xF5FBFD)
    static let subtle = Color(light: 0x526774, dark: 0xA8B5C3)
    static let tertiary = Color(light: 0x617784, dark: 0x7893A2)
    static let shellDeep = Color(light: 0x315B6F, dark: 0x3D6E85)
    static let shell = Color(light: 0x327E91, dark: 0x8DD8E8)
    static let primary = Color(light: 0x315B6F, dark: 0x8DD8E8)
    static let eyes = Color(light: 0x327E91, dark: 0xBCEAF1)
    static let amber = Color(light: 0xA84C08, dark: 0xE8A33D)
    static let coral = Color(light: 0xD52D4B, dark: 0xF26D80)

    /// Background for the selected navigation or list row.
    static let selection = Color(light: 0x3D6E85, dark: 0x8DD8E8, lightAlpha: 0.13, darkAlpha: 0.20)
}

enum DieterMetrics {
    static let browserWidth: CGFloat = 320
    static let browserMaximumWidth: CGFloat = 340
    static let sidebarExpandedWidth: CGFloat = 224
    static let sidebarCollapsedWidth: CGFloat = 58
    static let navigationRowHeight: CGFloat = 32
    static let controlRadius: CGFloat = 8
    static let cardRadius: CGFloat = 10
}

/// Shared type scale so every pane uses the same few text styles.
enum DieterFont {
    /// Prominent pane titles ("Chats", "Files", board name).
    static let paneTitle = Font.custom("Sora", size: 16).weight(.semibold)
    /// Titles of secondary headers (conversation title, detail panes).
    static let title = Font.custom("Sora", size: 13).weight(.semibold)
    /// Metadata line under a title.
    static let subtitle = Font.system(size: 11)
    /// Uppercased section labels (PROJECTS, MACHINES, …).
    static let sectionLabel = Font.custom("Sora", size: 10).weight(.semibold)
    /// Standard interactive rows and body copy.
    static let body = Font.system(size: 13)
    /// Secondary row text and compact controls.
    static let control = Font.custom("Sora", size: 12).weight(.medium)
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
        background: Color = DieterTheme.sidebar,
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
        background: Color = DieterTheme.sidebar,
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
                .font(prominent ? DieterFont.paneTitle : DieterFont.title)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(DieterFont.subtitle)
                    .foregroundStyle(DieterTheme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

struct DieterFlowLayout: Layout {
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
            .background(DieterTheme.surface.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(DieterTheme.border))
    }
}

extension View {
    func dieterSurface(radius: CGFloat = 12) -> some View { modifier(SurfaceModifier(radius: radius)) }
}

struct StatusPill: View {
    let text: String
    var color: Color = DieterTheme.subtle

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
struct DieterActivityIndicator: View {
    var color: Color = DieterTheme.primary
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

struct DieterIconButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(active ? DieterTheme.text : DieterTheme.subtle)
            .frame(width: 30, height: 28)
            .background(
                active ? DieterTheme.elevated : (configuration.isPressed ? DieterTheme.raised : DieterTheme.surface),
                in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct DieterPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13).frame(height: 30)
            .background(DieterTheme.shellDeep, in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct DieterSecondaryButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(destructive ? DieterTheme.coral : DieterTheme.subtle)
            .padding(.horizontal, 12).frame(height: 30)
            .background(DieterTheme.surface.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous).stroke(DieterTheme.border))
    }
}

struct DieterChipLabel: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = DieterTheme.subtle
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
        .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous))
    }
}

struct DieterSearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(DieterTheme.tertiary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(DieterTheme.tertiary)
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous))
    }
}

func runtimeColor(_ runtime: String) -> Color {
    switch runtime.lowercased() {
    case "running", "active", "working", "starting": DieterTheme.primary
    case "review", "waiting", "needs_input", "waiting_for_user": DieterTheme.amber
    case "completed", "done": DieterTheme.eyes
    case "idle": DieterTheme.subtle
    case "failed", "error", "cancelled": DieterTheme.coral
    default: DieterTheme.subtle
    }
}
