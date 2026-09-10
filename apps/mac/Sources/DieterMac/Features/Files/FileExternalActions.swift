import AppKit
import DieterAPI
import Foundation

struct FileOpeningApplication: Identifiable, Equatable {
    let url: URL
    let name: String
    let isDefault: Bool
    var id: String { url.path }

    static func ordered(_ applications: [Self]) -> [Self] {
        var unique: [String: Self] = [:]
        for application in applications {
            let key = application.url.standardizedFileURL.resolvingSymlinksInPath().path
            if unique[key] == nil || application.isDefault { unique[key] = application }
        }
        return unique.values.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            let names = $0.name.localizedStandardCompare($1.name)
            return names == .orderedSame ? $0.id < $1.id : names == .orderedAscending
        }
    }
}

struct FileExternalActions {
    let displayPath: String
    let fileURL: URL?
    let unavailableReason: String?
    var applications: [FileOpeningApplication] = []

    static func resolve(verifiedLocal: Bool, rootPath: String?, relativePath: String) -> Self {
        guard let rootPath, rootPath.hasPrefix("/"), !rootPath.contains("\0"),
            !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\0"),
            !relativePath.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
        else {
            return Self(
                displayPath: relativePath, fileURL: nil, unavailableReason: "Save a local copy to open this file.")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard verifiedLocal else {
            return Self(
                displayPath: candidate.path, fileURL: nil,
                unavailableReason: "This file is on another machine. Save a local copy to open it.")
        }
        let canonicalRoot = root.resolvingSymlinksInPath()
        let canonicalFile = candidate.resolvingSymlinksInPath()
        let prefix = canonicalRoot.path == "/" ? "/" : canonicalRoot.path + "/"
        guard canonicalFile.path.hasPrefix(prefix),
            (try? canonicalRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
            (try? canonicalFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else {
            return Self(
                displayPath: candidate.path, fileURL: nil,
                unavailableReason: "This file is not available in the local workspace. Save a local copy to open it.")
        }
        return Self(displayPath: candidate.path, fileURL: canonicalFile, unavailableReason: nil)
    }

    @MainActor
    mutating func loadApplications(workspace: NSWorkspace = .shared) {
        guard let fileURL else { return }
        let preferred = workspace.urlForApplication(toOpen: fileURL)?.standardizedFileURL.resolvingSymlinksInPath()
        let urls = workspace.urlsForApplications(toOpen: fileURL) + (preferred.map { [$0] } ?? [])
        applications = FileOpeningApplication.ordered(
            urls.map { url in
                let bundle = Bundle(url: url)
                let name =
                    bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                return FileOpeningApplication(
                    url: url, name: name,
                    isDefault: url.standardizedFileURL.resolvingSymlinksInPath() == preferred)
            })
    }

    @MainActor
    static func copy(_ value: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    @MainActor
    static func exportBytes(document: Dieter_V1_FileDocument, session: FileEditorSession, documentKey: String) -> Data {
        if !document.binary, session.documentKey == documentKey { return Data(session.currentText().utf8) }
        return ProjectFilePresentation.bytes(binary: document.binary, content: document.content, data: document.data)
    }

    @MainActor
    static func markdownExportDocument(
        document: Dieter_V1_FileDocument, session: FileEditorSession, documentKey: String
    ) -> MarkdownFileExport.Document? {
        guard !document.binary, ProjectFileLanguage.detect(filename: document.name) == .markdown,
            !documentKey.isEmpty, session.documentKey == documentKey
        else { return nil }
        return MarkdownFileExport.Document(name: document.name, source: session.currentText())
    }
}
