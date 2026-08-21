import AppKit
import NauclioAPI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ⌘V interception

extension View {
    /// Intercepts ⌘V in this view's window before the focused text view can
    /// swallow it, so images and files on the pasteboard become attachments.
    /// The handler returns true when it consumed the pasteboard; plain text
    /// pastes fall through to the focused control.
    func attachmentPasteCatcher(_ paste: @escaping (NSPasteboard) -> Bool) -> some View {
        background(AttachmentPasteMonitor(paste: paste).frame(width: 0, height: 0))
    }

    /// Accepts Finder files and dragged image data using the same item-provider
    /// path as paste, while exposing target state for a visible drop affordance.
    func attachmentDropTarget(
        isTargeted: Binding<Bool>,
        perform: @escaping ([NSItemProvider]) -> Void
    ) -> some View {
        onDrop(
            of: [UTType.fileURL.identifier, UTType.image.identifier],
            isTargeted: isTargeted
        ) { providers in
            guard !providers.isEmpty else { return false }
            perform(providers)
            return true
        }
    }
}

private struct AttachmentPasteMonitor: NSViewRepresentable {
    let paste: (NSPasteboard) -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.paste = paste
    }

    /// Holds the monitor token so it can be released from a nonisolated deinit.
    private final class MonitorBox: @unchecked Sendable {
        var token: Any?

        func remove() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }
    }

    final class MonitorView: NSView {
        var paste: ((NSPasteboard) -> Bool)?
        private let box = MonitorBox()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { box.remove() } else { installMonitor() }
        }

        private func installMonitor() {
            guard box.token == nil else { return }
            box.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "v",
                      self.paste?(NSPasteboard.general) == true else { return event }
                return nil
            }
        }

        deinit { box.remove() }
    }
}

// MARK: - Attachment previews

/// Horizontal strip of removable attachment previews shown in composers.
struct AttachmentPreviewStrip: View {
    @Binding var attachments: [Nauclio_V1_MessagePart]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, part in
                    AttachmentPreviewTile(part: part) { attachments.remove(at: index) }
                }
            }
            .padding(3)
        }
    }
}

/// One attachment preview: a real thumbnail for images, a labeled file card otherwise.
struct AttachmentPreviewTile: View {
    let part: Nauclio_V1_MessagePart
    var remove: (() -> Void)?
    @State private var hovering = false

    private static let thumbnails = NSCache<NSString, NSImage>()
    private static let tileHeight: CGFloat = 68

    var body: some View {
        Group {
            if let thumbnail { imageTile(thumbnail) } else { fileTile }
        }
        .overlay(alignment: .topTrailing) {
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 17, height: 17)
                        .background(Color.black.opacity(hovering ? 0.72 : 0.5), in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.25)))
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Remove attachment")
                .accessibilityLabel("Remove \(part.filename)")
            }
        }
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(part.filename), \(AttachmentSizeText.format(part.data.count))")
    }

    private func imageTile(_ image: NSImage) -> some View {
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let width = min(150, max(Self.tileHeight, Self.tileHeight * aspect))
        return ZStack(alignment: .bottomLeading) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: Self.tileHeight)
                .clipped()
            LinearGradient(
                colors: [.clear, .clear, Color.black.opacity(0.68)],
                startPoint: .top, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(part.filename)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(AttachmentSizeText.format(part.data.count))
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 5)
        }
        .frame(width: width, height: Self.tileHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(hovering ? NauclioTheme.aegean.opacity(0.55) : Color.white.opacity(0.14))
        )
        .shadow(color: Color.black.opacity(0.3), radius: 6, y: 3)
    }

    private var fileTile: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(NauclioTheme.cobalt.opacity(0.18))
                Image(systemName: "doc.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NauclioTheme.aegean)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(part.filename.isEmpty ? "Attachment" : part.filename)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("\(fileKind) · \(AttachmentSizeText.format(part.data.count))")
                    .font(.system(size: 9))
                    .foregroundStyle(NauclioTheme.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.tileHeight - 16)
        .frame(maxWidth: 200, alignment: .leading)
        .background(NauclioTheme.elevated.opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(hovering ? NauclioTheme.aegean.opacity(0.45) : NauclioTheme.border)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 5, y: 2)
    }

    private var fileKind: String {
        let suffix = (part.filename as NSString).pathExtension.uppercased()
        if !suffix.isEmpty { return suffix }
        return part.mediaType.split(separator: "/").last.map { String($0).uppercased() } ?? "FILE"
    }

    private var thumbnail: NSImage? {
        guard part.mediaType.hasPrefix("image/"), !part.data.isEmpty else { return nil }
        let key = "\(part.filename):\(part.data.count):\(part.data.hashValue)" as NSString
        if let cached = Self.thumbnails.object(forKey: key) { return cached }
        guard let image = NSImage(data: part.data) else { return nil }
        Self.thumbnails.setObject(image, forKey: key)
        return image
    }
}

enum AttachmentSizeText {
    static func format(_ bytes: Int) -> String {
        if bytes >= 1_024 * 1_024 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1_024 { return String(format: "%.0f KB", Double(bytes) / 1_024) }
        return "\(bytes) B"
    }
}
