import AppKit
import DieterAPI
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

    /// Reuses one importer/paste pipeline across every composer. Loading,
    /// normalization, limits, and errors all stay centralized in DieterStore.
    func attachmentIntake(
        store: DieterStore,
        importerPresented: Binding<Bool>,
        attachments: Binding<[Dieter_V1_MessagePart]>
    ) -> some View {
        modifier(AttachmentIntakeModifier(
            store: store,
            importerPresented: importerPresented,
            attachments: attachments
        ))
    }
}

private struct AttachmentIntakeModifier: ViewModifier {
    let store: DieterStore
    @Binding var importerPresented: Bool
    @Binding var attachments: [Dieter_V1_MessagePart]

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $importerPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                Task {
                    do { attachments = try await store.attachmentParts(try result.get(), appendingTo: attachments) }
                    catch { store.show(error) }
                }
            }
            // Keep keyboard paste on the AppKit monitor below. Installing a
            // SwiftUI paste command here as well can dispatch the same ⌘V to
            // both handlers and append one clipboard image twice.
            .attachmentPasteCatcher { pasteboard in
                guard let input = store.pasteboardAttachmentInput(pasteboard) else { return false }
                Task {
                    do { attachments = try await store.attachmentParts(input, appendingTo: attachments) }
                    catch { store.show(error) }
                }
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
    @Binding var attachments: [Dieter_V1_MessagePart]

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
    let part: Dieter_V1_MessagePart
    var remove: (() -> Void)?
    @State private var hovering = false
    @State private var previewPresented = false

    private static let tileHeight: CGFloat = 68

    var body: some View {
        Group {
            if let thumbnail { imageTile(thumbnail) } else { fileTile }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            if thumbnail != nil { previewPresented = true }
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
        .help(thumbnail == nil ? "" : "Preview \(part.filename.isEmpty ? "image" : part.filename)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(part.filename), \(AttachmentSizeText.format(part.data.count))")
        .accessibilityAddTraits(thumbnail == nil ? [] : .isButton)
        .accessibilityAction(named: "Preview") {
            if thumbnail != nil { previewPresented = true }
        }
        .sheet(isPresented: $previewPresented) {
            if let thumbnail {
                AttachmentImagePreview(part: part, image: thumbnail)
            }
        }
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
                .stroke(hovering ? DieterTheme.shell.opacity(0.55) : Color.white.opacity(0.14))
        )
        .shadow(color: Color.black.opacity(0.3), radius: 6, y: 3)
    }

    private var fileTile: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DieterTheme.shellDeep.opacity(0.18))
                Image(systemName: "doc.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DieterTheme.shell)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(part.filename.isEmpty ? "Attachment" : part.filename)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("\(fileKind) · \(AttachmentSizeText.format(part.data.count))")
                    .font(.system(size: 9))
                    .foregroundStyle(DieterTheme.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.tileHeight - 16)
        .frame(maxWidth: 200, alignment: .leading)
        .background(DieterTheme.elevated.opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(hovering ? DieterTheme.shell.opacity(0.45) : DieterTheme.border)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 5, y: 2)
    }

    private var fileKind: String {
        let suffix = (part.filename as NSString).pathExtension.uppercased()
        if !suffix.isEmpty { return suffix }
        return part.mediaType.split(separator: "/").last.map { String($0).uppercased() } ?? "FILE"
    }

    private var thumbnail: NSImage? {
        guard part.mediaType.hasPrefix("image/") || part.type.caseInsensitiveCompare("image") == .orderedSame else { return nil }
        return AttachmentImagePayload.image(from: part)
    }
}

enum AttachmentImagePayload {
    private final class ImageCache: @unchecked Sendable {
        let values: NSCache<NSString, NSImage> = {
            let cache = NSCache<NSString, NSImage>()
            cache.countLimit = 128
            cache.totalCostLimit = 64 * 1_024 * 1_024
            return cache
        }()
    }

    private static let cache = ImageCache()

    static func image(from part: Dieter_V1_MessagePart) -> NSImage? {
        let key = cacheKey(for: part)
        if let cached = cache.values.object(forKey: key) { return cached }
        let image: NSImage?
        if !part.data.isEmpty {
            image = NSImage(data: part.data)
        } else if let marker = part.url.range(of: ";base64,") {
            image = Data(base64Encoded: String(part.url[marker.upperBound...])).flatMap(NSImage.init(data:))
        } else {
            image = nil
        }
        if let image { cache.values.setObject(image, forKey: key, cost: max(1, part.data.count)) }
        return image
    }

    private static func cacheKey(for part: Dieter_V1_MessagePart) -> NSString {
        let prefix = part.data.prefix(16).base64EncodedString()
        let suffix = part.data.suffix(16).base64EncodedString()
        return "\(part.filename)|\(part.payloadRevision)|\(part.data.count)|\(prefix)|\(suffix)|\(part.url)" as NSString
    }
}

struct AttachmentImagePreview: View {
    @Environment(\.dismiss) private var dismiss
    let part: Dieter_V1_MessagePart
    let image: NSImage

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(part.filename.isEmpty ? "Image attachment" : part.filename)
                        .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))  ·  \(AttachmentSizeText.format(part.data.count))")
                        .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(DieterIconButtonStyle()).help("Close preview")
            }
            .padding(.horizontal, 18).frame(height: 56)
            Divider().overlay(DieterTheme.border)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
                .background(DieterTheme.surface)
                .accessibilityLabel(part.filename.isEmpty ? "Image preview" : "Preview of \(part.filename)")
        }
        .frame(minWidth: 620, idealWidth: 820, minHeight: 480, idealHeight: 660)
        .background(DieterTheme.background)
    }
}

enum AttachmentSizeText {
    static func format(_ bytes: Int) -> String {
        if bytes >= 1_024 * 1_024 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1_024 { return String(format: "%.0f KB", Double(bytes) / 1_024) }
        return "\(bytes) B"
    }
}
