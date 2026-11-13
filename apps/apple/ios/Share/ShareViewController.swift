import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let destinationStack = UIStackView()
    private let newTaskButton = UIButton(type: .system)
    private let taskButton = UIButton(type: .system)
    private let chatButton = UIButton(type: .system)
    private let folderButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var started = false
    private var readyToComplete = false
    private var stagedID: String?
    /// Why the staged files cannot be attached to a task or chat; nil when they can.
    private var attachmentProblem: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.text = "Preparing files…"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "ios.share.status"
        spinner.startAnimating()

        configure(
            newTaskButton, title: "New Task", subtitle: "Create a task with this attachment",
            image: "square.and.pencil", identifier: "ios.share.new-task", action: #selector(openNewTask))
        configure(
            taskButton, title: "Add to Task", subtitle: "Choose an existing board task",
            image: "checklist", identifier: "ios.share.task", action: #selector(openTask))
        configure(
            chatButton, title: "Use in Chat", subtitle: "Choose an existing chat",
            image: "bubble.left.and.bubble.right", identifier: "ios.share.chat", action: #selector(openChat))
        configure(
            folderButton, title: "Save to Folder…", subtitle: "Keep the files in a synced folder",
            image: "folder", identifier: "ios.share.folder", action: #selector(openFolder))
        destinationStack.axis = .vertical
        destinationStack.alignment = .fill
        destinationStack.spacing = 10
        destinationStack.isHidden = true
        [newTaskButton, taskButton, chatButton, folderButton].forEach(destinationStack.addArrangedSubview)

        closeButton.setTitle("Cancel", for: .normal)
        closeButton.accessibilityIdentifier = "ios.share.cancel"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel, destinationStack, closeButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await prepareShare() }
    }

    private func configure(
        _ button: UIButton, title: String, subtitle: String, image: String, identifier: String,
        action: Selector
    ) {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.subtitle = subtitle
        configuration.image = UIImage(systemName: image)
        configuration.imagePadding = 12
        configuration.imagePlacement = .leading
        configuration.titleAlignment = .leading
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        button.configuration = configuration
        button.contentHorizontalAlignment = .fill
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func prepareShare() async {
        do {
            let providers =
                extensionContext?.inputItems
                .compactMap { $0 as? NSExtensionItem }
                .flatMap { $0.attachments ?? [] } ?? []
            let staged = try await SharePayloadWriter.stage(providers: providers)
            stagedID = staged.id
            spinner.stopAnimating()
            statusLabel.text = "Where should this go?"
            if let problem = staged.attachmentProblem {
                // Too many or too large for a task or chat; a folder takes them.
                attachmentProblem = problem
                for button in [newTaskButton, taskButton, chatButton] {
                    button.configuration?.subtitle = problem
                }
            }
            setDestinationButtonsEnabled(true)
            destinationStack.isHidden = false
        } catch {
            spinner.stopAnimating()
            statusLabel.text = error.localizedDescription
            destinationStack.isHidden = true
            closeButton.setTitle("Close", for: .normal)
        }
    }

    @objc private func openNewTask() { prepareHandoff(destination: "new-task") }

    @objc private func openTask() { prepareHandoff(destination: "task") }

    @objc private func openChat() { prepareHandoff(destination: "chat") }

    @objc private func openFolder() { prepareHandoff(destination: "folder") }

    private func prepareHandoff(destination: String) {
        guard let stagedID else {
            statusLabel.text = SharePayloadError.unavailable.localizedDescription
            return
        }
        setDestinationButtonsEnabled(false)
        do {
            try SharePayloadWriter.prepareHandoff(id: stagedID, destination: destination)
            readyToComplete = true
            destinationStack.isHidden = true
            statusLabel.text = "Ready in Dieter. Tap Done, then open Dieter to continue."
            closeButton.setTitle("Done", for: .normal)
            closeButton.accessibilityIdentifier = "ios.share.done"
        } catch {
            statusLabel.text = error.localizedDescription
            setDestinationButtonsEnabled(true)
        }
    }

    private func setDestinationButtonsEnabled(_ enabled: Bool) {
        newTaskButton.isEnabled = enabled && attachmentProblem == nil
        taskButton.isEnabled = enabled && attachmentProblem == nil
        chatButton.isEnabled = enabled && attachmentProblem == nil
        folderButton.isEnabled = enabled
    }

    @objc private func close() {
        if readyToComplete {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        extensionContext?.cancelRequest(
            withError: NSError(
                domain: "DieterShare", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: statusLabel.text ?? "The share could not be completed."
                ]))
    }
}

private enum SharePayloadError: LocalizedError {
    case noItems
    case tooMany
    case tooManyFiles
    case fileTooLarge(String)
    case totalTooLarge
    case unavailable

    var errorDescription: String? {
        switch self {
        case .noItems: "Choose a screenshot or file to share with Dieter."
        case .tooMany: "Dieter accepts up to 4 attachments."
        case .tooManyFiles: "Dieter accepts up to 100 files at once."
        case .fileTooLarge(let name): "\(name) must be at most 5 MB."
        case .totalTooLarge: "Attachments must total at most 6 MB."
        case .unavailable: "The shared item could not be read."
        }
    }
}

/// A shared file copied into the request's directory, never read into memory.
private struct StagedFile: Sendable {
    let size: Int64
    let filename: String?
    let mediaType: String?
}

@MainActor
private enum SharePayloadWriter {
    private struct Manifest: Encodable {
        struct Item: Encodable {
            let storedName: String
            let filename: String
            let mediaType: String
            let size: Int64
        }

        let items: [Item]
    }

    private struct PendingRequest: Encodable {
        let id: String
        let destination: String
    }

    struct Staged {
        let id: String
        /// Why the files cannot be attached to a task or chat; a folder still takes them.
        let attachmentProblem: String?
    }

    private static let maximumCount = 4
    private static let maximumFolderCount = 100
    private static let maximumBytes: Int64 = 5 * 1_024 * 1_024
    private static let maximumTotalBytes: Int64 = 6 * 1_024 * 1_024
    private static let destinations = ["new-task", "task", "chat", "folder"]

    /// Copies every shared item into a new request directory of the App Group's ShareInbox.
    /// Attachments have size limits; a synced folder takes up to 100 files of any size.
    static func stage(providers: [NSItemProvider]) async throws -> Staged {
        guard !providers.isEmpty else { throw SharePayloadError.noItems }
        guard providers.count <= maximumFolderCount else { throw SharePayloadError.tooManyFiles }
        let container = try sharedContainer()
        let inbox = container.appendingPathComponent("ShareInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        removeExpiredItems(from: inbox)
        let id = UUID().uuidString.lowercased()
        let directory = inbox.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            var items: [Manifest.Item] = []
            for (index, provider) in providers.enumerated() {
                items.append(try await stage(provider, index: index, into: directory))
            }
            try JSONEncoder().encode(Manifest(items: items)).write(
                to: directory.appendingPathComponent("manifest.json"),
                options: [.atomic, .completeFileProtection])
            return Staged(id: id, attachmentProblem: attachmentProblem(items))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func attachmentProblem(_ items: [Manifest.Item]) -> String? {
        if items.count > maximumCount { return SharePayloadError.tooMany.localizedDescription }
        if let large = items.first(where: { $0.size > maximumBytes }) {
            return SharePayloadError.fileTooLarge(large.filename).localizedDescription
        }
        if items.reduce(0, { $0 + $1.size }) > maximumTotalBytes {
            return SharePayloadError.totalTooLarge.localizedDescription
        }
        return nil
    }

    static func prepareHandoff(id: String, destination: String) throws {
        guard let uuid = UUID(uuidString: id), destinations.contains(destination) else {
            throw SharePayloadError.unavailable
        }
        let inbox = try sharedContainer().appendingPathComponent("ShareInbox", isDirectory: true)
        let canonicalID = uuid.uuidString.lowercased()
        let directory = inbox.appendingPathComponent(canonicalID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else {
            throw SharePayloadError.unavailable
        }
        try JSONEncoder().encode(PendingRequest(id: canonicalID, destination: destination)).write(
            to: inbox.appendingPathComponent("pending-request.json"),
            options: [.atomic, .completeFileProtection])
    }

    private static func sharedContainer() throws -> URL {
        guard
            let group = Bundle.main.object(forInfoDictionaryKey: "DieterAppGroupIdentifier") as? String,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group)
        else { throw SharePayloadError.unavailable }
        return container
    }

    private static func stage(_ provider: NSItemProvider, index: Int, into directory: URL) async throws
        -> Manifest.Item
    {
        let staging = directory.appendingPathComponent("incoming-\(index)")
        let file: StagedFile
        let type: UTType?
        let fallback: String
        // Files can offer image bytes without a suggested name alongside its
        // file URL. Read the file representation first to retain its metadata.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            file = try await provider.copySharedFile(to: staging)
            type = file.mediaType.flatMap { UTType(mimeType: $0) }
            fallback = "Attachment \(index + 1)"
        } else {
            let preferredImages: [UTType] = [.png, .jpeg, .heic, .gif]
            let identifier: String
            if let image = preferredImages.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                identifier = image.identifier
                fallback = "Screenshot \(index + 1)"
            } else if let image = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            }) {
                identifier = image
                fallback = "Screenshot \(index + 1)"
            } else if let content = preferredContentTypeIdentifier(for: provider) {
                identifier = content
                fallback = "Attachment \(index + 1)"
            } else {
                throw SharePayloadError.unavailable
            }
            file = try await provider.copyFileRepresentation(forTypeIdentifier: identifier, to: staging)
            type = UTType(identifier)
        }
        guard file.size > 0 else { throw SharePayloadError.unavailable }
        let suggested = (file.filename ?? provider.suggestedName)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var filename = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        if URL(fileURLWithPath: filename).pathExtension.isEmpty, let suffix = type?.preferredFilenameExtension {
            filename += ".\(suffix)"
        }
        let safeName = URL(fileURLWithPath: filename).lastPathComponent
        let suffix = URL(fileURLWithPath: safeName).pathExtension
        let storedName = suffix.isEmpty ? "attachment-\(index)" : "attachment-\(index).\(suffix)"
        try FileManager.default.moveItem(at: staging, to: directory.appendingPathComponent(storedName))
        return Manifest.Item(
            storedName: storedName, filename: safeName,
            mediaType: type?.preferredMIMEType
                ?? UTType(filenameExtension: suffix)?.preferredMIMEType
                ?? "application/octet-stream",
            size: file.size)
    }

    private static func preferredContentTypeIdentifier(for provider: NSItemProvider) -> String? {
        let registered = provider.registeredTypeIdentifiers
        return registered.first { identifier in
            guard let type = UTType(identifier), !type.conforms(to: .url) else { return false }
            return type.conforms(to: .content) || type.conforms(to: .data)
        }
    }

    private static func removeExpiredItems(from inbox: URL) {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let values =
            (try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
        let datedValues = values.map { url in
            (
                url,
                try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            )
        }.sorted { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) }
        for (index, value) in datedValues.enumerated() {
            if value.1 == nil || value.1! < cutoff || index >= 7 {
                try? FileManager.default.removeItem(at: value.0)
            }
        }
    }
}

@MainActor
extension NSItemProvider {
    /// Copies the item's `identifier` representation to `destination`; the provider's file is
    /// valid only inside its callback.
    fileprivate func copyFileRepresentation(forTypeIdentifier identifier: String, to destination: URL)
        async throws -> StagedFile
    {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StagedFile, Error>) in
            _ = loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw SharePayloadError.unavailable }
                    try FileManager.default.copyItem(at: url, to: destination)
                    let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    continuation.resume(returning: StagedFile(size: Int64(size), filename: nil, mediaType: nil))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Copies a shared file URL (security scoped when it comes from another app) to `destination`.
    fileprivate func copySharedFile(to destination: URL) async throws -> StagedFile {
        let suggestedName = suggestedName
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StagedFile, Error>) in
            loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                do {
                    if let error { throw error }
                    let url: URL?
                    if let value = item as? URL {
                        url = value
                    } else if let value = item as? NSURL {
                        url = value as URL
                    } else if let value = item as? Data {
                        url = URL(dataRepresentation: value, relativeTo: nil)
                    } else {
                        url = nil
                    }
                    guard let url else { throw SharePayloadError.unavailable }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile != false else { throw SharePayloadError.unavailable }
                    try FileManager.default.copyItem(at: url, to: destination)
                    let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? values.fileSize ?? 0
                    continuation.resume(
                        returning: StagedFile(
                            size: Int64(size), filename: suggestedName ?? url.lastPathComponent,
                            mediaType: values.contentType?.preferredMIMEType))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
