import AppKit
import SwiftUI

enum DieterAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "DieterAppearance"
    static let defaultsSuiteFlag = "--appearance-defaults-suite"
    static let defaultValue = DieterAppearance.system

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

enum DieterPalette: String, CaseIterable, Identifiable {
    case monochrome
    case electricBlue = "electric-blue"
    case jadeOperator = "jade-operator"
    case copperCircuit = "copper-circuit"
    case ultravioletRelay = "ultraviolet-relay"
    case solarCommand = "solar-command"
    case arcticConsole = "arctic-console"
    case coralSignal = "coral-signal"

    static let storageKey = "DieterPalette"
    static let defaultValue = DieterPalette.monochrome

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monochrome: "Monochrome"
        case .electricBlue: "Electric Blue"
        case .jadeOperator: "Jade Operator"
        case .copperCircuit: "Copper Circuit"
        case .ultravioletRelay: "Ultraviolet Relay"
        case .solarCommand: "Solar Command"
        case .arcticConsole: "Arctic Console"
        case .coralSignal: "Coral Signal"
        }
    }

    static func resolve(_ storedValue: String?) -> DieterPalette {
        if storedValue == "acid-terminal" { return .monochrome }
        return storedValue.flatMap(Self.init(rawValue:)) ?? defaultValue
    }

    static var selected: DieterPalette {
        resolve(DieterAppearance.applicationDefaults().string(forKey: storageKey))
    }

    var previewColors: [Color] {
        [spec.shellStart, spec.shellEnd, spec.paneEnd].map { Color(nsColor: NSColor(rgb: $0)) }
    }

    fileprivate var spec: PaletteSpec {
        switch self {
        case .monochrome:
            PaletteSpec(0x1C1C1E, 0x2C2C2E, 0xE5E5EA, 0x636366, 0xF2F2F7, 0x8E8E93, 0xD1D1D6, 0xF5F5F7, 0x0B0B0C, 0x1C1C1E)
        case .electricBlue:
            PaletteSpec(0x071426, 0x102746, 0x22D3EE, 0x2563EB, 0x73F4E4, 0x2588F5, 0x5EEAD4, 0xFAF9F6, 0x040C18, 0x0B1C33)
        case .jadeOperator:
            PaletteSpec(0x06211D, 0x123C32, 0x34D399, 0x087F5B, 0xA7F3D0, 0x14B8A6, 0xD1FAE5, 0xF4FBF8, 0x041412, 0x0B2C26)
        case .copperCircuit:
            PaletteSpec(0x1A1210, 0x3A241A, 0xF59E6C, 0xB84C2F, 0xFFD08A, 0xE97850, 0xFFE0B2, 0xFFF8F1, 0x100B0A, 0x271A14)
        case .ultravioletRelay:
            PaletteSpec(0x130C2B, 0x2B1850, 0xC084FC, 0x6D5EF8, 0xE9D5FF, 0xA855F7, 0xDDD6FE, 0xFCFAFF, 0x0C071B, 0x1D113B)
        case .solarCommand:
            PaletteSpec(0x151A22, 0x34321C, 0xFDE047, 0xF59E0B, 0xFEF3C7, 0xFB923C, 0xFDE68A, 0xFFFBEA, 0x0D1015, 0x22241F)
        case .arcticConsole:
            PaletteSpec(0x0D1B24, 0x193A49, 0x8DD8E8, 0x3D6E85, 0xD7F2F5, 0x62B6CB, 0xBCEAF1, 0xF5FBFD, 0x081116, 0x122834)
        case .coralSignal:
            PaletteSpec(0x28101F, 0x4A1D33, 0xFF8A7A, 0xE44568, 0xFFD0C7, 0xFF6B8A, 0xFFD6CC, 0xFFF5F3, 0x190A13, 0x361527)
        }
    }
}

private struct PaletteSpec {
    let darkBrand: UInt32
    let darkRaised: UInt32
    let shellStart: UInt32
    let shellEnd: UInt32
    let paneStart: UInt32
    let paneEnd: UInt32
    let eyes: UInt32
    let light: UInt32
    let darkBackground: UInt32
    let darkSurface: UInt32

    init(
        _ darkBrand: UInt32,
        _ darkRaised: UInt32,
        _ shellStart: UInt32,
        _ shellEnd: UInt32,
        _ paneStart: UInt32,
        _ paneEnd: UInt32,
        _ eyes: UInt32,
        _ light: UInt32,
        _ darkBackground: UInt32,
        _ darkSurface: UInt32
    ) {
        self.darkBrand = darkBrand
        self.darkRaised = darkRaised
        self.shellStart = shellStart
        self.shellEnd = shellEnd
        self.paneStart = paneStart
        self.paneEnd = paneEnd
        self.eyes = eyes
        self.light = light
        self.darkBackground = darkBackground
        self.darkSurface = darkSurface
    }

    var lightSurface: UInt32 { mix(light, 0xFFFFFF, amount: 0.72) }
    var lightRaised: UInt32 { mix(light, darkRaised, amount: 0.07) }
    var lightSidebar: UInt32 { mix(light, darkBrand, amount: 0.045) }
    var lightSubtle: UInt32 { mix(darkBrand, light, amount: 0.34) }
    var lightTertiary: UInt32 { mix(darkBrand, light, amount: 0.43) }
    var darkElevated: UInt32 { mix(darkRaised, paneEnd, amount: 0.16) }
    var darkInput: UInt32 { mix(darkBackground, 0x000000, amount: 0.18) }
    var darkSubtle: UInt32 { mix(light, darkBrand, amount: 0.30) }
    var darkTertiary: UInt32 { mix(light, darkBrand, amount: 0.48) }
}

private func mix(_ first: UInt32, _ second: UInt32, amount: Double) -> UInt32 {
    let clamped = min(max(amount, 0), 1)
    func channel(_ shift: UInt32) -> UInt32 {
        let a = Double((first >> shift) & 0xff)
        let b = Double((second >> shift) & 0xff)
        return UInt32((a + ((b - a) * clamped)).rounded())
    }
    return (channel(16) << 16) | (channel(8) << 8) | channel(0)
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

/// Palette-backed surfaces adapted for native Aqua and Dark Aqua while retaining
/// a consistent contrast hierarchy across every supplied Dieter palette.
enum DieterTheme {
    private static var colors: PaletteSpec { DieterPalette.selected.spec }

    static var background: Color { Color(light: colors.light, dark: colors.darkBackground) }
    static var sidebar: Color { Color(light: colors.lightSidebar, dark: colors.darkBrand) }
    static var surface: Color { Color(light: colors.lightSurface, dark: colors.darkSurface) }
    static var raised: Color { Color(light: colors.lightRaised, dark: colors.darkRaised) }
    static var elevated: Color { Color(light: colors.paneStart, dark: colors.darkElevated) }
    static var input: Color { Color(light: colors.lightSurface, dark: colors.darkInput) }
    static var border: Color { Color(light: colors.darkBrand, dark: colors.eyes, lightAlpha: 0.10, darkAlpha: 0.09) }
    static var strongBorder: Color { Color(light: colors.darkBrand, dark: colors.eyes, lightAlpha: 0.18, darkAlpha: 0.16) }
    /// Crisp 1px seam separating the three primary panes (nav · workspace · conversation).
    static var paneSeparator: Color { Color(light: colors.darkBrand, dark: colors.eyes, lightAlpha: 0.22, darkAlpha: 0.18) }
    static var text: Color { Color(light: colors.darkBrand, dark: colors.light) }
    static var subtle: Color { Color(light: colors.lightSubtle, dark: colors.darkSubtle) }
    static var tertiary: Color { Color(light: colors.lightTertiary, dark: colors.darkTertiary) }
    static var shellDeep: Color { Color(light: colors.shellEnd, dark: colors.shellEnd) }
    static var shell: Color { Color(light: colors.shellEnd, dark: colors.shellStart) }
    static var primary: Color { Color(light: colors.shellEnd, dark: colors.shellStart) }
    static var eyes: Color { Color(light: colors.shellEnd, dark: colors.eyes) }
    static let amber = Color(light: 0xA84C08, dark: 0xE8A33D)
    static let coral = Color(light: 0xD52D4B, dark: 0xF26D80)

    /// Background for the selected navigation or list row.
    static var selection: Color { Color(light: colors.shellEnd, dark: colors.shellStart, lightAlpha: 0.13, darkAlpha: 0.20) }

    static var terminalBackground: Color { Color(nsColor: terminalBackgroundColor) }
    static var terminalBackgroundColor: NSColor { NSColor(rgb: colors.darkBackground) }
    static var terminalForegroundColor: NSColor { NSColor(rgb: colors.light) }
    static var terminalCaretColor: NSColor { NSColor(rgb: colors.shellStart) }
}

enum DieterMetrics {
    static let browserWidth: CGFloat = 320
    static let browserMaximumWidth: CGFloat = 340
    static let sidebarExpandedWidth: CGFloat = 234
    static let sidebarCollapsedWidth: CGFloat = 60
    static let navigationRowHeight: CGFloat = 32
    static let controlRadius: CGFloat = 8
    static let cardRadius: CGFloat = 10
    /// Shared top inset for every pane header so titles land on one horizontal band.
    static let headerTopPadding: CGFloat = 14
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
        .padding(.top, DieterMetrics.headerTopPadding)
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
