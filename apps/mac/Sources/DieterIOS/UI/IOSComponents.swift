#if os(iOS)
    import DieterAPI
    import SwiftUI
    import Textual

    struct IOSStatusBadge: View {
        let state: String

        private var tint: Color {
            switch state.lowercased() {
            case "running", "starting", "resuming", "connected": .green
            case "failed", "error", "offline": .orange
            case "waiting", "queued", "pending": .blue
            default: .secondary
            }
        }

        var body: some View {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(state.isEmpty ? "Idle" : state.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    struct IOSTaskRow: View {
        let card: Dieter_V1_Card
        var projectName: String?
        var machineName: String?
        var machineOnline = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(card.title.isEmpty ? "Untitled task" : card.title)
                    .font(.headline)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
                if let projectName, !projectName.isEmpty {
                    Text(projectName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !card.ownerDaemonID.isEmpty {
                    Label(
                        "\(machineName ?? card.ownerDaemonID)\(machineOnline ? "" : " · Offline")",
                        systemImage: "desktopcomputer"
                    )
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 10) {
                    IOSStatusBadge(state: card.runtime)
                    if !card.lane.isEmpty {
                        Text(card.lane.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if card.commentCount > 0 {
                        Label("\(card.commentCount)", systemImage: "text.bubble")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 5)
            .accessibilityElement(children: .combine)
        }
    }

    struct IOSMessageText: View {
        let text: String

        private var accessibilityText: AttributedString {
            (try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        }

        var body: some View {
            StructuredText(markdown: text)
                .textual.structuredTextStyle(.gitHub)
                .textual.textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Keep each message exposed as the same single StaticText
                // element used by VoiceOver and the UI smoke journey. Textual
                // remains responsible for the richer visual block hierarchy.
                .accessibilityRepresentation { Text(accessibilityText) }
        }
    }

    struct IOSConnectionBanner: View {
        let title: String
        var detail: String = ""
        var isConnecting = false
        var retry: (() -> Void)?
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var shimmer = false

        private let tint = Color(red: 0.94, green: 0.47, blue: 0.20)

        var body: some View {
            HStack(spacing: 10) {
                if isConnecting {
                    IOSDieterActivityGlyph(size: 22, tint: tint)
                } else {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(tint)
                        .frame(width: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .overlay {
                            if isConnecting, !reduceMotion {
                                GeometryReader { geometry in
                                    LinearGradient(
                                        colors: [.clear, tint.opacity(0.95), .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                    .frame(width: geometry.size.width)
                                    .offset(x: shimmer ? geometry.size.width : -geometry.size.width)
                                }
                                .mask(Text(title).font(.subheadline.weight(.medium)))
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            }
                        }
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                if let retry {
                    Button("Retry", action: retry)
                        .font(.subheadline.weight(.semibold))
                        .tint(tint)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 56)
            .modifier(
                IOSGlassCardModifier(
                    shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ios.connection.banner")
            .onChange(of: isConnecting, initial: true) { _, connecting in
                guard connecting, !reduceMotion else {
                    shimmer = false
                    return
                }
                shimmer = false
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                    shimmer = true
                }
            }
        }
    }

    struct IOSWorkspaceBackdrop: View {
        var body: some View {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                RadialGradient(
                    colors: [Color.accentColor.opacity(0.13), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 420
                )
                LinearGradient(
                    colors: [Color.white.opacity(0.08), .clear, Color.accentColor.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        }
    }

    struct IOSFloatingGlassModifier<GlassShape: Shape>: ViewModifier {
        let shape: GlassShape

        @ViewBuilder func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.stroke(Color.secondary.opacity(0.18), lineWidth: 0.75))
            }
        }
    }

    struct IOSGlassCardModifier<GlassShape: Shape>: ViewModifier {
        let shape: GlassShape

        @ViewBuilder func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content
                    .background(.regularMaterial, in: shape)
                    .overlay(shape.stroke(Color.white.opacity(0.24), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
            }
        }
    }

    enum IOSWorkspaceDestination: Hashable {
        case allTasks
        case chats
        case screens
        case project(String)
        case board(String)
    }

    struct IOSFileScope: Identifiable {
        let machineID: String
        let projectID: String
        let checkoutID: String
        let cardID: String
        let title: String
        var id: String { machineID + ":" + checkoutID + ":" + cardID }
    }
#endif
