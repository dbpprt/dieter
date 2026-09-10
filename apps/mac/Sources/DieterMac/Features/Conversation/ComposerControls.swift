import DieterAPI
import SwiftUI

/// Shared visual structure; each conversation keeps ownership of its draft and actions.
struct ComposerSurface<Content: View>: View {
    let focused: Bool
    let dropTargeted: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(dropTargeted ? DieterTheme.shellDeep.opacity(0.12) : DieterTheme.surface)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        dropTargeted
                            ? DieterTheme.shell
                            : (focused ? DieterTheme.shellDeep.opacity(0.55) : DieterTheme.border),
                        lineWidth: dropTargeted ? 1.5 : 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
            .animation(.easeOut(duration: 0.16), value: focused)
            .animation(.easeOut(duration: 0.12), value: dropTargeted)
    }
}

struct ComposerTextInput: View {
    let placeholder: String
    @Binding var text: String
    let focus: FocusState<Bool>.Binding

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(1...5)
            .focused(focus)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44, alignment: .topLeading)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { focus.wrappedValue = true }
            }
    }
}

struct ComposerToolbarMetrics {
    let width: CGFloat
    var compact: Bool { width < 360 }
}

/// Interactive controls are mounted once. Only their visual labels compact.
struct ComposerToolbar<Content: View>: View {
    @ViewBuilder var content: (ComposerToolbarMetrics) -> Content

    var body: some View {
        GeometryReader { geometry in
            let metrics = ComposerToolbarMetrics(width: geometry.size.width)
            HStack(spacing: metrics.compact ? 4 : 6) {
                content(metrics)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DieterTheme.subtle)
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 30)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

struct ComposerSelectionMenu<Content: View>: View {
    let title: String
    let symbol: String
    let help: String
    var compact = false
    var maximumWidth: CGFloat = 180
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            ComposerMenuLabelLayout(maximumWidth: maximumWidth) {
                HStack(spacing: 3) {
                    if compact {
                        Image(systemName: symbol).frame(width: 14)
                    } else {
                        Text(title).lineLimit(1).truncationMode(.tail)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("\(help): \(title)")
        .quickHelp(help)
    }
}

/// Reserve only the selected label's width, while allowing long names to truncate.
private struct ComposerMenuLabelLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let label = subviews.first else { return .zero }
        let ideal = label.sizeThatFits(.unspecified)
        let width = min(ideal.width, maximumWidth, proposal.width ?? .infinity)
        return CGSize(width: width, height: max(28, ideal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

struct ComposerAttachmentButton: View {
    let identifierPrefix: String
    let identity: String
    var isEnabled = true
    let onUpload: () -> Void
    var onCapture: (() -> Void)?
    @State private var presented = false

    var body: some View {
        Button {
            if onCapture == nil {
                onUpload()
            } else {
                presented = true
            }
        } label: {
            Image(systemName: "paperclip")
        }
        .buttonStyle(DieterIconButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel("Attach")
        .accessibilityIdentifier("\(identifierPrefix).attach")
        .smokeTarget("\(identifierPrefix).attach")
        .quickHelp("Attach")
        .popover(isPresented: $presented) {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    presented = false
                    onUpload()
                } label: {
                    Label("Upload file…", systemImage: "doc.badge.plus")
                }
                .accessibilityIdentifier("\(identifierPrefix).attach.upload")
                .smokeTarget("\(identifierPrefix).attach.upload")
                if let onCapture {
                    Button {
                        presented = false
                        onCapture()
                    } label: {
                        Label("Take screenshot…", systemImage: "viewfinder")
                    }
                    .accessibilityIdentifier("\(identifierPrefix).attach.capture")
                    .smokeTarget("\(identifierPrefix).attach.capture")
                }
            }
            .buttonStyle(ComposerPopoverRowButtonStyle())
            .disabled(!isEnabled)
            .padding(6)
            .frame(minWidth: 210)
        }
        .onChange(of: identity) { _, _ in presented = false }
        .onDisappear { presented = false }
    }
}

/// Menu-like rows keep native button actions and accessibility inside a popover.
struct ComposerPopoverRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        private var highlighted: Bool { isEnabled && (hovered || configuration.isPressed) }

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(highlighted ? Color.white : Color.primary)
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(highlighted ? Color.accentColor : Color.clear)
                        .overlay {
                            if isEnabled && configuration.isPressed {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.black.opacity(0.12))
                            }
                        }
                }
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovered = $0 }
        }
    }
}

struct ComposerSendButton: View {
    let isEnabled: Bool
    var submitting = false
    var queuesMessage = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: submitting ? "hourglass" : "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isEnabled ? Color.white : DieterTheme.tertiary)
                .frame(width: 30, height: 30)
                .background(isEnabled ? DieterTheme.primary : DieterTheme.elevated, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(isEnabled ? 0.14 : 0.055)))
                .shadow(color: DieterTheme.shellDeep.opacity(isEnabled ? 0.3 : 0), radius: 9, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .quickHelp(queuesMessage ? "Queue" : "Send")
        .accessibilityLabel(queuesMessage ? "Queue message" : "Send message")
    }
}

/// Fast remains directly accessible; other provider fields share one popover.
struct ComposerProviderOptions: View {
    let options: [Dieter_V1_ProviderOption]
    @Binding var values: [String: String]
    var conversationLocked = false
    let identity: String
    let identifierPrefix: String
    @State private var presented = false

    private var additionalOptions: [Dieter_V1_ProviderOption] { options.filter { $0.id != "fast_mode" } }

    var body: some View {
        HStack(spacing: 4) {
            if let fast = options.first(where: { $0.id == "fast_mode" }) {
                ProviderOptionChip(
                    option: fast, values: $values,
                    isEnabled: ProviderOptionValues.isEnabled(fast, conversationLocked: conversationLocked)
                )
                .smokeTarget("\(identifierPrefix).fast-mode")
            }
            if !additionalOptions.isEmpty {
                Button {
                    presented = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Provider options")
                .accessibilityIdentifier("\(identifierPrefix).additional-options")
                .smokeTarget("\(identifierPrefix).additional-options")
                .quickHelp("Provider options")
                .popover(isPresented: $presented) {
                    Form {
                        ForEach(additionalOptions, id: \.id) { option in
                            ProviderOptionField(option: option, values: $values)
                                .disabled(
                                    !ProviderOptionValues.isEnabled(option, conversationLocked: conversationLocked)
                                )
                                .smokeTarget("\(identifierPrefix).other-option.\(option.id)")
                        }
                    }
                    .formStyle(.grouped)
                    .frame(width: 320)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: identity) { _, _ in presented = false }
        .onChange(of: options) { _, _ in presented = false }
        .onDisappear { presented = false }
    }
}
