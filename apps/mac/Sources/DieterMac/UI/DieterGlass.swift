import SwiftUI

// Liquid Glass building blocks shared by every pane. Each decoration switches
// between glass and its solid fallback through modifiers, never through
// branches, so view identity, focus, and text selection survive a change of
// the transparency setting.

/// The visual states of an L2 tile: cards, rows, and list items.
enum DieterTileState: Equatable {
    case rest
    case hover
    case selected
    case targeted

    init(selected: Bool, hovering: Bool = false, targeted: Bool = false) {
        self = targeted ? .targeted : selected ? .selected : hovering ? .hover : .rest
    }

    @MainActor var fill: Color {
        switch self {
        case .rest: DieterTheme.tile
        case .hover: DieterTheme.tileHover
        case .selected, .targeted: DieterTheme.tileSelected
        }
    }

    @MainActor var rim: Color {
        switch self {
        case .rest, .hover: DieterTheme.tileRim
        case .selected: DieterTheme.tileRimSelected
        case .targeted: DieterTheme.shell.opacity(0.6)
        }
    }
}

/// A floating L1 panel: the sidebar card, the conversation panel, overlays.
private struct DieterPanelModifier: ViewModifier {
    let radius: CGFloat
    var shadow = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let solidShadow = shadow && !DieterTheme.usesTransparency
        content
            // Only the panel's own shape casts the solid-mode shadow. A shadow
            // on the content would render every hosted editor offscreen.
            .background {
                shape
                    .fill(DieterTheme.usesTransparency ? Color.clear : DieterTheme.panelSolid)
                    .shadow(
                        color: .black.opacity(solidShadow ? (DieterTheme.isDark ? 0.32 : 0.1) : 0),
                        radius: solidShadow ? 10 : 0, y: solidShadow ? 3 : 0)
            }
            .glassEffect(
                DieterTheme.usesTransparency ? .regular.tint(DieterTheme.panelTint) : .identity, in: shape
            )
            .overlay { shape.strokeBorder(DieterTheme.panelRim, lineWidth: 1).allowsHitTesting(false) }
    }
}

/// An L2 tile: a translucent fill and a hairline rim, never a backdrop sample.
private struct DieterTileModifier: ViewModifier {
    let state: DieterTileState
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(state.fill, in: shape)
            .overlay {
                shape.strokeBorder(state.rim, lineWidth: state == .targeted ? 1.5 : 1).allowsHitTesting(false)
            }
    }
}

/// A recessed well inside a panel: machines, expanded tool lists, code.
private struct DieterInsetModifier: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(DieterTheme.inset, in: shape)
            .overlay { shape.strokeBorder(DieterTheme.insetRim, lineWidth: 1).allowsHitTesting(false) }
    }
}

/// L3 control chrome: a glass capsule or circle, tinted when prominent.
private struct DieterControlChrome<S: InsettableShape>: ViewModifier {
    let shape: S
    var prominent = false
    var interactive = true
    var prominentTint: Color?

    func body(content: Content) -> some View {
        let tint: Color? = prominent ? (prominentTint ?? DieterTheme.action) : nil
        let glass: Glass = interactive ? .regular.tint(tint).interactive() : .regular.tint(tint)
        content
            .background(
                DieterTheme.usesTransparency
                    ? Color.clear : (prominent ? (prominentTint ?? DieterTheme.action) : DieterTheme.controlSolid),
                in: shape
            )
            .glassEffect(DieterTheme.usesTransparency ? glass : .identity, in: shape)
            .overlay {
                shape.strokeBorder(prominent ? Color.white.opacity(0.18) : DieterTheme.controlRim, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func dieterPanel(radius: CGFloat = DieterMetrics.panelRadius, shadow: Bool = true) -> some View {
        modifier(DieterPanelModifier(radius: radius, shadow: shadow))
    }

    func dieterTile(_ state: DieterTileState = .rest, radius: CGFloat = DieterMetrics.cardRadius) -> some View {
        modifier(DieterTileModifier(state: state, radius: radius))
    }

    /// Detail content (a conversation, an editor) as a floating glass panel,
    /// clipped to the panel's corners.
    func dieterConversationPanel(radius: CGFloat = DieterMetrics.panelRadius) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .dieterPanel(radius: radius)
    }

    func dieterInset(radius: CGFloat = 10) -> some View {
        modifier(DieterInsetModifier(radius: radius))
    }

    /// Capsule chrome for bar controls that are not buttons, such as menus.
    func dieterCapsuleChrome(prominent: Bool = false, interactive: Bool = true, tint: Color? = nil) -> some View {
        modifier(
            DieterControlChrome(shape: Capsule(), prominent: prominent, interactive: interactive, prominentTint: tint))
    }

    func dieterCircleChrome(prominent: Bool = false, tint: Color? = nil) -> some View {
        modifier(DieterControlChrome(shape: Circle(), prominent: prominent, prominentTint: tint))
    }

    /// Control chrome in any outline, for tracks that hold more than one line.
    func dieterControlChrome<S: InsettableShape>(_ shape: S, interactive: Bool = true) -> some View {
        modifier(DieterControlChrome(shape: shape, interactive: interactive))
    }
}

/// A floating row of glass controls sharing one sampling region.
struct DieterGlassBar<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            HStack(spacing: spacing) { content }
        }
    }
}

/// A section: its glass top bar in the title band, then its content in a
/// floating panel. Every section ends its bar with search and New Task.
struct DieterSectionScaffold<Leading: View, Trailing: View, Content: View>: View {
    var showsSearch = true
    var showsQuickTask = true
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            DieterPaneTopBar(
                leadingPadding: DieterMetrics.panelGap, trailingInset: DieterMetrics.windowInset
            ) {
                leading
            } trailing: {
                trailing
                if showsSearch { DieterSearchCapsule(width: 180) }
                if showsQuickTask { GlobalQuickTaskButton() }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dieterConversationPanel()
                .padding(.leading, DieterMetrics.panelGap)
                .padding([.trailing, .bottom], DieterMetrics.windowInset)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// A pane's glass top bar in the window's title band, aligned with the window
/// controls and clear of them while the sidebar is hidden.
struct DieterPaneTopBar<Leading: View, Trailing: View>: View {
    @Environment(\.dieterTitleBandLeadingInset) private var leadingInset
    var leadingPadding: CGFloat = 14
    var trailingInset: CGFloat = 6
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        DieterGlassBar {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .padding(.leading, leadingPadding + leadingInset)
        .padding(.trailing, trailingInset)
        .padding(.top, DieterMetrics.titleBandTop)
        .frame(height: DieterMetrics.titleBandHeight, alignment: .top)
        .background(DieterTitleBandRegion())
    }
}

/// A section title as a quiet glass capsule: "Terminals 3", with an optional
/// tertiary status beside it.
struct DieterTitleCapsule: View {
    let title: String
    var count: Int?
    var symbol: String?
    var detail: String = ""

    var body: some View {
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
            Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            if let count {
                Text("\(count)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(DieterTheme.tertiary)
            }
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(DieterTheme.tertiary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .foregroundStyle(DieterTheme.text)
        .padding(.horizontal, 14).frame(height: DieterMetrics.capsuleHeight)
        .dieterCapsuleChrome(interactive: false)
        .accessibilityElement(children: .combine)
    }
}

/// A bar button: a glass capsule, a circle for icons, or the blue primary action.
struct DieterBarButtonStyle: ButtonStyle {
    enum Outline {
        case capsule
        case circle
    }

    var shape: Outline = .capsule
    var prominent = false
    var destructive = false
    /// The prominent fill; the blue action colour when nil.
    var tint: Color?
    var size: CGFloat = DieterMetrics.capsuleHeight

    func makeBody(configuration: Configuration) -> some View {
        DieterBarButtonBody(style: self, label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct DieterBarButtonBody<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let style: DieterBarButtonStyle
    let label: Label
    let pressed: Bool

    var body: some View {
        let size = style.size
        let content =
            label
            .font(.system(size: size < 30 ? 11 : 12.5, weight: style.prominent ? .semibold : .medium))
            .foregroundStyle(
                style.prominent ? Color.white : (style.destructive ? DieterTheme.failed : DieterTheme.text)
            )
            .lineLimit(1)
            .padding(.horizontal, style.shape == .circle ? 0 : (size < 30 ? 10 : 13))
            .frame(width: style.shape == .circle ? size : nil, height: size)
            .opacity(pressed ? 0.72 : 1)
        Group {
            switch style.shape {
            case .capsule:
                content.contentShape(Capsule()).dieterCapsuleChrome(prominent: style.prominent, tint: style.tint)
            case .circle:
                content.contentShape(Circle()).dieterCircleChrome(prominent: style.prominent, tint: style.tint)
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A labelled bar button with the shared title band height.
struct DieterBarButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    var iconOnly = false
    var size: CGFloat = DieterMetrics.capsuleHeight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if iconOnly, let symbol {
                Image(systemName: symbol).font(.system(size: size < 30 ? 11 : 13, weight: .medium))
            } else {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                    Text(title)
                }
            }
        }
        .buttonStyle(DieterBarButtonStyle(shape: iconOnly ? .circle : .capsule, prominent: prominent, size: size))
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The global command palette launcher shown at the top of every pane.
struct DieterSearchCapsule: View {
    @Environment(DieterStore.self) private var store
    var width: CGFloat = 220

    var body: some View {
        Button {
            store.commandPalettePresented = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .medium))
                Text("Search")
                Spacer(minLength: 8)
                Text("⌘K").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(DieterTheme.tertiary)
            .frame(width: width - 26, alignment: .leading)
        }
        .buttonStyle(DieterBarButtonStyle())
        .help("Search and commands (⌘K)")
        .accessibilityLabel("Search and commands")
        .accessibilityIdentifier("workspace.search")
    }
}

/// A `Menu` label sized like a bar button: an icon circle, or a capsule with
/// an optional symbol, a title and a chevron. Pair it with `dieterMenuChrome`.
struct DieterMenuLabel: View {
    var title: String?
    var symbol: String?
    var showsChevron = true
    var size: CGFloat = DieterMetrics.capsuleHeight

    var body: some View {
        Group {
            if let title {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                    Text(title).lineLimit(1)
                    if showsChevron {
                        Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(DieterTheme.tertiary)
                    }
                }
                .font(.system(size: size < 30 ? 11 : 12.5, weight: .medium))
                .padding(.horizontal, size < 30 ? 10 : 13)
                .frame(height: size)
                .contentShape(Capsule())
            } else {
                Image(systemName: symbol ?? "ellipsis")
                    .font(.system(size: size < 30 ? 11 : 12.5, weight: .semibold))
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
        }
        .foregroundStyle(DieterTheme.text)
    }
}

/// Glass chrome for a `Menu` whose label is sized like a bar button.
private struct DieterMenuChromeModifier: ViewModifier {
    let shape: DieterBarButtonStyle.Outline
    let prominent: Bool

    func body(content: Content) -> some View {
        let menu = content.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        switch shape {
        case .capsule: menu.dieterCapsuleChrome(prominent: prominent)
        case .circle: menu.dieterCircleChrome(prominent: prominent)
        }
    }
}

extension View {
    /// Turns a `Menu` into a glass bar control; size its label with `DieterMenuLabel`.
    func dieterMenuChrome(_ shape: DieterBarButtonStyle.Outline = .capsule, prominent: Bool = false) -> some View {
        modifier(DieterMenuChromeModifier(shape: shape, prominent: prominent))
    }
}

/// The glass replacement for `.pickerStyle(.segmented)`: one capsule track
/// with a lighter thumb on the selected option.
struct DieterSegmentedPicker<Value: Hashable, Label: View>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    var fillsWidth = false
    var height: CGFloat = DieterMetrics.segmentHeight
    @ViewBuilder var label: (Value) -> Label

    var body: some View {
        DieterSegmentTrack(height: height, fillsWidth: fillsWidth) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    label(option)
                }
                .buttonStyle(
                    DieterSegmentStyle(selected: option == selection, fillsWidth: fillsWidth, height: height - 6)
                )
                .accessibilityAddTraits(option == selection ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension DieterSegmentedPicker where Label == Text {
    init(
        _ title: String, selection: Binding<Value>, options: [Value], fillsWidth: Bool = false,
        height: CGFloat = DieterMetrics.segmentHeight, optionTitle: @escaping (Value) -> String
    ) {
        self.init(
            title: title, selection: selection, options: options, fillsWidth: fillsWidth, height: height,
            label: { Text(optionTitle($0)) })
    }
}

/// A toggle drawn as a glass capsule chip, filled with its tint while on.
struct DieterChipToggleStyle: ToggleStyle {
    var tint: Color?
    var size: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(DieterBarButtonStyle(prominent: configuration.isOn, tint: tint, size: size))
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// A joined glass capsule holding several borderless segments.
struct DieterSegmentTrack<Content: View>: View {
    var height: CGFloat = DieterMetrics.capsuleHeight
    var fillsWidth = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(3)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: height, maxHeight: height, alignment: .leading)
            .dieterCapsuleChrome(interactive: false)
    }
}

/// One segment in a `DieterSegmentTrack`; the selected segment carries a lighter thumb.
struct DieterSegmentStyle: ButtonStyle {
    let selected: Bool
    var fillsWidth = false
    var height: CGFloat = DieterMetrics.capsuleHeight - 6

    func makeBody(configuration: Configuration) -> some View {
        DieterSegmentBody(
            label: configuration.label, selected: selected, pressed: configuration.isPressed,
            fillsWidth: fillsWidth, height: height)
    }
}

private struct DieterSegmentBody<Label: View>: View {
    let label: Label
    let selected: Bool
    let pressed: Bool
    let fillsWidth: Bool
    let height: CGFloat
    @State private var hovering = false

    var body: some View {
        label
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? DieterTheme.text : DieterTheme.subtle)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: height, maxHeight: height)
            .background {
                Capsule()
                    .fill(
                        selected
                            ? DieterTheme.segmentThumb
                            : (hovering || pressed ? DieterTheme.tileHover : Color.clear)
                    )
                    .shadow(color: .black.opacity(selected && !DieterTheme.isDark ? 0.08 : 0), radius: 1.5, y: 0.5)
            }
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: selected)
    }
}

/// A segment label with an optional symbol and a tertiary count.
struct DieterSegmentLabel: View {
    let title: String
    var symbol: String?
    var count: Int?
    var showsTitle = true

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)) }
            if showsTitle { Text(title) }
            if let count, count > 0 {
                Text("\(count)").foregroundStyle(DieterTheme.tertiary).monospacedDigit()
            }
        }
    }
}

/// A compact count capsule.
struct DieterCountBadge: View {
    let count: Int
    var tint: Color?

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(tint ?? DieterTheme.subtle)
            .padding(.horizontal, 6)
            .frame(minWidth: 19, minHeight: 18)
            .background((tint ?? DieterTheme.subtle).opacity(tint == nil ? 0.12 : 0.16), in: Capsule())
    }
}

/// A small status dot in a runtime colour.
struct DieterStatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// An inline tinted block for work that needs the user.
struct DieterCallout: View {
    let text: String
    var tint: Color = DieterTheme.attention
    var symbol = "exclamationmark.triangle"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.32), lineWidth: 1)
        }
    }
}

/// A sentence-case section heading with an optional trailing accessory.
struct DieterSectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(DieterTheme.tertiary)
            Spacer(minLength: 6)
            accessory
        }
    }
}

extension DieterSectionHeader where Accessory == EmptyView {
    init(title: String) {
        self.title = title
        accessory = EmptyView()
    }
}

/// A navigation row: symbol, title, and a trailing count or dot.
struct DieterNavRow<Trailing: View>: View {
    let title: String
    var symbol: String?
    let selected: Bool
    var leadingDot: Color?
    @ViewBuilder var trailing: Trailing
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12.5, weight: .regular))
                        .frame(width: 17)
                        .foregroundStyle(selected ? DieterTheme.text : DieterTheme.subtle)
                }
                if let leadingDot { DieterStatusDot(color: leadingDot, size: 6) }
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DieterTheme.text : DieterTheme.text.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                trailing
            }
            .padding(.horizontal, 9)
            .frame(height: DieterMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
                    .fill(selected ? DieterTheme.tileSelected : (hovering ? DieterTheme.tileHover : .clear))
            }
            .overlay {
                RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
                    .strokeBorder(selected ? DieterTheme.tileRim : .clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A trailing tertiary count for navigation rows.
struct DieterRowCount: View {
    let count: Int
    var attention = false

    var body: some View {
        HStack(spacing: 5) {
            if attention { DieterStatusDot(color: DieterTheme.attention, size: 6) }
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(DieterTheme.tertiary)
        }
    }
}

/// `+12 −4 3f` in diff colours.
struct DieterDiffStat: View {
    let additions: Int
    let deletions: Int
    var files: Int = 0

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(additions)").foregroundStyle(DieterTheme.diffAddition)
            Text("−\(deletions)").foregroundStyle(DieterTheme.diffDeletion)
            if files > 0 { Text("\(files)f").foregroundStyle(DieterTheme.tertiary) }
        }
        .font(DieterFont.mono)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(additions) additions, \(deletions) deletions, \(files) files")
    }
}

/// A branch glyph and the branch name in mono.
struct DieterBranchLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5, weight: .medium))
            Text(text).font(DieterFont.mono).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(DieterTheme.tertiary)
    }
}

/// A small rounded chip, e.g. `Codex · gpt-5`.
struct DieterChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DieterTheme.text.opacity(0.9))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(DieterTheme.tileHover, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(DieterTheme.tileRim, lineWidth: 1)
            }
    }
}
