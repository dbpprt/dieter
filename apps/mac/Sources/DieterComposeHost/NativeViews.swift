import DieterShared
import DieterAPI
import SharedCore
import UIKit
import Observation
import UniformTypeIdentifiers
import QuickLook
@preconcurrency import PhotosUI
@preconcurrency import SwiftTerm

@MainActor
final class ComposeNativeViews: NSObject, @preconcurrency MobileNativeViews {
    private var picker: AttachmentPicker?
    private var photos: PhotoPicker?
    private var preview: AttachmentPreview?
    let media: CoreScreenMedia
    init(media: CoreScreenMedia) { self.media = media }
    func pickAttachments(receiver: any MobileAttachmentReceiver) {
        let chooser = UIAlertController(title: "Attach images or files", message: nil, preferredStyle: .actionSheet)
        chooser.addAction(
            UIAlertAction(title: "Photo library", style: .default) { [weak self] _ in
                guard let self else { return }
                var configuration = PHPickerConfiguration(); configuration.filter = .images;
                configuration.selectionLimit = 4
                let source = PhotoPicker(receiver: receiver); photos = source
                let controller = PHPickerViewController(configuration: configuration); controller.delegate = source
                Self.presenting?.present(controller, animated: true)
            })
        chooser.addAction(
            UIAlertAction(title: "Choose files", style: .default) { [weak self] _ in
                self?.pickDocuments(receiver: receiver)
            })
        chooser.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let presenter = Self.presenting {
            chooser.popoverPresentationController?.sourceView = presenter.view;
            chooser.popoverPresentationController?.sourceRect = CGRect(
                x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 80, width: 1, height: 1);
            presenter.present(chooser, animated: true)
        }
    }
    private func pickDocuments(receiver: any MobileAttachmentReceiver) {
        let picker = AttachmentPicker(receiver: receiver)
        self.picker = picker
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        controller.allowsMultipleSelection = true; controller.delegate = picker
        Self.presenting?.present(controller, animated: true)
    }
    func previewAttachment(part data: Data) {
        guard let part = try? Dieter_V1_MessagePart(serializedBytes: data) else { return }
        let bytes =
            part.data.isEmpty
            ? Data(base64Encoded: part.url.components(separatedBy: ";base64,").last ?? "") ?? Data() : part.data
        guard !bytes.isEmpty, bytes.count <= 6 * 1024 * 1024 else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "attachment-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        { try? FileManager.default.removeItem(at: old) }
        let file = directory.appendingPathComponent(
            URL(fileURLWithPath: part.filename.isEmpty ? "attachment" : part.filename).lastPathComponent)
        guard (try? bytes.write(to: file, options: .atomic)) != nil else { return }
        let source = AttachmentPreview(url: file); preview = source
        let controller = QLPreviewController(); controller.dataSource = source
        Self.presenting?.present(controller, animated: true)
    }
    private static var presenting: UIViewController? {
        var controller = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
            .first { $0.isKeyWindow }?.rootViewController
        while let next = controller?.presentedViewController { controller = next }
        return controller
    }
    func terminal(input: any MobileTerminalInput) -> any MobileTerminalSurface { ComposeTerminal(input: input) }
    func screen(scope: String, input: any MobileScreenInput) -> any MobileScreenSurface {
        ComposeScreen(scope: scope, input: input, media: media)
    }
}

@MainActor
private final class ComposeTerminal: SwiftTerm.TerminalView, @preconcurrency MobileTerminalSurface,
    @preconcurrency TerminalViewDelegate
{
    private let input: any MobileTerminalInput
    private var acceptsInput = false
    var view: UIView { self }
    init(input: any MobileTerminalInput) {
        self.input = input
        super.init(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
        nativeBackgroundColor = UIColor(white: 0.04, alpha: 1)
        terminalDelegate = self
        accessibilityLabel = "Remote terminal"
    }
    required init?(coder: NSCoder) { nil }
    func key(value: Int32) {
        guard acceptsInput else { return }
        input.send(
            data: SharedRules.shared.terminalKey(
                key: value, shift: false, alt: false, control: false, applicationCursor: getTerminal().applicationCursor
            ))
    }
    func reset() { let reset: [UInt8] = [0x1b, 0x63]; feed(byteArray: reset[...]) }
    func feed(data: Data) { let bytes = [UInt8](data); feed(byteArray: bytes[...]) }
    func setInputEnabled(enabled: Bool) { acceptsInput = enabled }
    func close() { resignFirstResponder(); terminalDelegate = nil }
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        if acceptsInput { input.send(data: Data(data)) }
    }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        input.resize(columns: Int32(newCols), rows: Int32(newRows))
    }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["https", "http"].contains(url.scheme) { UIApplication.shared.open(url) }
    }
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        UIPasteboard.general.string = String(data: content, encoding: .utf8)
    }
}

@MainActor @Observable
private final class ComposeScreen: NSObject, IOSScreenCanvasController, @preconcurrency MobileScreenSurface {
    let renderer = IOSScreenVideoView(frame: .zero)
    let scope: String
    let input: any MobileScreenInput
    let media: CoreScreenMedia
    private(set) var slice = ClientScreenSlice()
    private(set) var cursorImage: UIImage?
    private(set) var hostCursorRevision = 0
    private(set) var canvasRevision = 0
    @ObservationIgnored private var nativeView: IOSScreenInputView?
    @ObservationIgnored private(set) lazy var touch = SharedTouchScreen(
        scope: scope, slop: 8, doubleTapSlop: 100, doubleTapTimeoutMillis: 300,
        sink: ScreenInputSink { [weak self] data in self?.input.send(command: data) })
    var view: UIView {
        if let nativeView { return nativeView }; let created = IOSScreenInputView(controller: self);
        nativeView = created; return created
    }
    var sessionState: Dieter_V1_RemoteDesktopSessionState { slice.state }
    var streaming: Bool { slice.streaming }
    var controlActive: Bool { slice.controlActive }
    var cursor: ScreenCursorState { ScreenCursorState(slice) }
    var hostCursor: CGPoint { CGPoint(x: slice.cursorX, y: slice.cursorY) }
    var phase: String { slice.phase }
    init(scope: String, input: any MobileScreenInput, media: CoreScreenMedia) {
        self.scope = scope; self.input = input; self.media = media
        super.init()
        media.attach(scope: scope, renderer: renderer)
    }
    func update(slice data: Data) {
        guard let next = try? ClientScreenSlice(serializedBytes: data) else { return }
        if slice.controlActive && !next.controlActive { touch.touchesCancelled() }
        slice = next
        if !next.cursorImageUnchanged { cursorImage = UIImage(data: next.cursorImage) }
        hostCursorRevision &+= 1
    }
    func setViewport(_ size: CGSize, scale: CGFloat) {
        let command = ClientScreenCommand.with {
            $0.scope = scope;
            $0.viewport = .with {
                $0.widthPoints = size.width; $0.heightPoints = size.height; $0.scale = scale
            }
        }
        if let data = try? command.serializedData() { input.send(command: data) }
    }
    // Canvas layout calls this callback; it must not trigger another layout.
    func canvasChanged() {}
    func control(action: String) {
        switch action {
        case "zoom-in", "zoom-out":
            touch.zoomBy(factor: action == "zoom-in" ? 1.25 : 0.8, centerX: view.bounds.midX, centerY: view.bounds.midY)
            canvasRevision &+= 1
        case "fit": touch.fit(); canvasRevision &+= 1
        case "keyboard-show": nativeView?.showSoftwareKeyboard(true)
        case "keyboard-hide": nativeView?.showSoftwareKeyboard(false)
        default: break
        }
    }
    func close() { touch.touchesCancelled(); nativeView?.release(); media.detach(scope: scope) }
}
private final class ScreenInputSink: NSObject, SharedTouchScreenSink, Sendable {
    private let deliver: @MainActor @Sendable (Data) -> Void
    init(_ deliver: @escaping @MainActor @Sendable (Data) -> Void) { self.deliver = deliver }
    func send(command: Data) { MainActor.assumeIsolated { deliver(command) } }
}

@MainActor private final class AttachmentPicker: NSObject, UIDocumentPickerDelegate {
    let receiver: any MobileAttachmentReceiver
    init(receiver: any MobileAttachmentReceiver) { self.receiver = receiver }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let receiver = receiver
        Task {
            do {
                let message = try await Task.detached {
                    guard urls.count <= 4 else { throw CocoaError(.fileReadTooLarge) }
                    var parts: [Dieter_V1_MessagePart] = []
                    var total = 0
                    for url in urls {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size > 0, size <= 5 * 1024 * 1024, total + size <= 6 * 1024 * 1024 else {
                            throw CocoaError(.fileReadTooLarge)
                        }
                        let bytes = try Data(contentsOf: url)
                        guard bytes.count <= 5 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                        total += bytes.count
                        parts.append(
                            .with {
                                $0.type = "file"; $0.filename = url.lastPathComponent;
                                $0.mediaType =
                                    UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                                    ?? "application/octet-stream";
                                $0.data = bytes
                            })
                    }
                    return try Dieter_V1_UiMessage.with { $0.parts = parts }.serializedData()
                }.value
                receiver.picked(message: message)
            } catch {
                receiver.failed(message: "Could not attach files. Choose up to 4 files, 5 MB each and 6 MB total.")
            }
        }
    }
}
@MainActor private final class AttachmentPreview: NSObject, QLPreviewControllerDataSource {
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        url as NSURL
    }
}

@MainActor private final class PhotoPicker: NSObject, PHPickerViewControllerDelegate {
    let receiver: any MobileAttachmentReceiver
    init(receiver: any MobileAttachmentReceiver) { self.receiver = receiver }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        Task {
            do {
                var parts: [Dieter_V1_MessagePart] = []
                var total = 0
                for result in results {
                    let provider = result.itemProvider
                    guard
                        let identifier = provider.registeredTypeIdentifiers.first(where: {
                            UTType($0)?.conforms(to: .image) == true
                        })
                    else { throw CocoaError(.fileReadUnsupportedScheme) }
                    let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                        provider.loadDataRepresentation(forTypeIdentifier: identifier) { bytes, error in
                            if let error {
                                continuation.resume(throwing: error)
                            } else if let bytes {
                                continuation.resume(returning: bytes)
                            } else {
                                continuation.resume(throwing: CocoaError(.fileReadUnknown))
                            }
                        }
                    }
                    total += bytes.count
                    guard bytes.count <= 5 * 1024 * 1024, total <= 6 * 1024 * 1024 else {
                        throw CocoaError(.fileReadTooLarge)
                    }
                    let type = UTType(identifier)
                    parts.append(
                        .with {
                            $0.type = "file";
                            $0.filename = "image-\(parts.count + 1).\(type?.preferredFilenameExtension ?? "jpg")";
                            $0.mediaType = type?.preferredMIMEType ?? "image/jpeg"; $0.data = bytes
                        })
                }
                receiver.picked(message: try Dieter_V1_UiMessage.with { $0.parts = parts }.serializedData())
            } catch {
                receiver.failed(message: "Could not attach photos. Choose up to 4 images, 5 MB each and 6 MB total.")
            }
        }
    }
}
