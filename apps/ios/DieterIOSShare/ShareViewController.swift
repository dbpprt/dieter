import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let closeButton = UIButton(type: .system)
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.text = "Preparing attachments…"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        spinner.startAnimating()
        closeButton.setTitle("Close", for: .normal)
        closeButton.isHidden = true
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel, closeButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await handOffToDieter() }
    }

    private func handOffToDieter() async {
        do {
            let providers =
                extensionContext?.inputItems
                .compactMap { $0 as? NSExtensionItem }
                .flatMap { $0.attachments ?? [] } ?? []
            let id = try await SharePayloadWriter.stage(providers: providers)
            guard let url = URL(string: "dieter-mac://share?id=\(id)") else {
                throw SharePayloadError.couldNotOpen
            }
            guard let extensionContext else { throw SharePayloadError.couldNotOpen }
            statusLabel.text = "Opening Dieter…"
            let opened = await withCheckedContinuation { continuation in
                extensionContext.open(url) { continuation.resume(returning: $0) }
            }
            guard opened else { throw SharePayloadError.couldNotOpen }
            extensionContext.completeRequest(returningItems: nil)
        } catch {
            spinner.stopAnimating()
            statusLabel.text = error.localizedDescription
            closeButton.isHidden = false
        }
    }

    @objc private func close() {
        extensionContext?.cancelRequest(
            withError: NSError(
                domain: "DieterShare", code: 1,
                userInfo: [NSLocalizedDescriptionKey: statusLabel.text ?? "The share could not be completed."]))
    }
}

private enum SharePayloadError: LocalizedError {
    case noItems
    case tooMany
    case fileTooLarge(String)
    case totalTooLarge
    case unavailable
    case couldNotOpen

    var errorDescription: String? {
        switch self {
        case .noItems: "Choose a screenshot or file to share with Dieter."
        case .tooMany: "Dieter accepts up to 4 attachments."
        case .fileTooLarge(let name): "\(name) must be at most 5 MB."
        case .totalTooLarge: "Attachments must total at most 6 MB."
        case .unavailable: "The shared item could not be read."
        case .couldNotOpen: "Dieter could not be opened. Close this sheet and try again."
        }
    }
}

private struct SharedFileRepresentation: Sendable {
    let data: Data
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
        }

        let items: [Item]
    }

    private struct Payload: Sendable {
        let data: Data
        let filename: String
        let mediaType: String
    }

    private static let maximumCount = 4
    private static let maximumBytes = 5 * 1_024 * 1_024
    private static let maximumTotalBytes = 6 * 1_024 * 1_024

    static func stage(providers: [NSItemProvider]) async throws -> String {
        guard !providers.isEmpty else { throw SharePayloadError.noItems }
        guard providers.count <= maximumCount else { throw SharePayloadError.tooMany }
        var payloads: [Payload] = []
        payloads.reserveCapacity(providers.count)
        for (index, provider) in providers.enumerated() {
            payloads.append(try await payload(provider, index: index))
        }
        guard payloads.reduce(0, { $0 + $1.data.count }) <= maximumTotalBytes else {
            throw SharePayloadError.totalTooLarge
        }
        guard let group = Bundle.main.object(forInfoDictionaryKey: "DieterAppGroupIdentifier") as? String,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group)
        else { throw SharePayloadError.unavailable }
        let inbox = container.appendingPathComponent("ShareInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        removeExpiredItems(from: inbox)
        let id = UUID().uuidString.lowercased()
        let directory = inbox.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            var items: [Manifest.Item] = []
            for (index, payload) in payloads.enumerated() {
                let suffix = URL(fileURLWithPath: payload.filename).pathExtension
                let storedName = suffix.isEmpty ? "attachment-\(index)" : "attachment-\(index).\(suffix)"
                try payload.data.write(
                    to: directory.appendingPathComponent(storedName), options: [.atomic, .completeFileProtection])
                items.append(
                    .init(storedName: storedName, filename: payload.filename, mediaType: payload.mediaType))
            }
            try JSONEncoder().encode(Manifest(items: items)).write(
                to: directory.appendingPathComponent("manifest.json"), options: [.atomic, .completeFileProtection])
            return id
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func payload(_ provider: NSItemProvider, index: Int) async throws -> Payload {
        let preferredImages: [UTType] = [.png, .jpeg, .heic, .gif]
        if let type = preferredImages.first(where: {
            provider.hasItemConformingToTypeIdentifier($0.identifier)
        }) {
            let data = try await provider.loadDataRepresentation(forTypeIdentifier: type.identifier)
            return try validatedPayload(
                data: data, suggestedName: provider.suggestedName,
                type: type, fallback: "Screenshot \(index + 1)")
        }
        if let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) {
            let data = try await provider.loadDataRepresentation(forTypeIdentifier: identifier)
            return try validatedPayload(
                data: data, suggestedName: provider.suggestedName,
                type: UTType(identifier), fallback: "Screenshot \(index + 1)")
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let file = try await provider.loadSharedFileRepresentation()
            return try validatedPayload(
                data: file.data, suggestedName: file.filename,
                type: file.mediaType.flatMap { UTType(mimeType: $0) }, fallback: "Attachment \(index + 1)")
        }
        guard let identifier = preferredContentTypeIdentifier(for: provider) else {
            throw SharePayloadError.unavailable
        }
        let data = try await provider.loadDataRepresentation(forTypeIdentifier: identifier)
        let type = UTType(identifier)
        return try validatedPayload(
            data: data, suggestedName: provider.suggestedName,
            type: type, fallback: "Attachment \(index + 1)")
    }

    private static func validatedPayload(
        data: Data, suggestedName: String?, type: UTType?, fallback: String
    ) throws -> Payload {
        let suggested = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        var filename = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        if URL(fileURLWithPath: filename).pathExtension.isEmpty, let suffix = type?.preferredFilenameExtension {
            filename += ".\(suffix)"
        }
        let safeName = URL(fileURLWithPath: filename).lastPathComponent
        guard !data.isEmpty else { throw SharePayloadError.unavailable }
        guard data.count <= maximumBytes else { throw SharePayloadError.fileTooLarge(safeName) }
        return Payload(
            data: data, filename: safeName,
            mediaType: type?.preferredMIMEType
                ?? UTType(filenameExtension: URL(fileURLWithPath: safeName).pathExtension)?.preferredMIMEType
                ?? "application/octet-stream")
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
private extension NSItemProvider {
    func loadDataRepresentation(forTypeIdentifier identifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: SharePayloadError.unavailable)
                }
            }
        }
    }

    func loadSharedFileRepresentation() async throws -> SharedFileRepresentation {
        let suggestedName = suggestedName
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<SharedFileRepresentation, Error>) in
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
                    let values = try url.resourceValues(
                        forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile != false else { throw SharePayloadError.unavailable }
                    let filename = suggestedName ?? url.lastPathComponent
                    if let size = values.fileSize, size > 5 * 1_024 * 1_024 {
                        throw SharePayloadError.fileTooLarge(filename)
                    }
                    continuation.resume(
                        returning: SharedFileRepresentation(
                            data: try Data(contentsOf: url, options: [.mappedIfSafe]),
                            filename: filename,
                            mediaType: values.contentType?.preferredMIMEType))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
