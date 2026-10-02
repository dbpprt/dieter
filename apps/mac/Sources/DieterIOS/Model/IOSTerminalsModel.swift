import Foundation

struct IOSTerminalScreenState: Equatable, Sendable {
    private(set) var chunks: [Data] = []
    private(set) var byteCount = 0
    private(set) var revision = 0
    private(set) var resetRevision = 0

    mutating func apply(data: Data, reset: Bool, limit: Int = 2 * 1_024 * 1_024) {
        if reset {
            chunks = data.isEmpty ? [] : Self.chunked(data)
            byteCount = data.count
            resetRevision += 1
        } else if !data.isEmpty {
            chunks.append(contentsOf: Self.chunked(data))
            byteCount += data.count
        }
        if byteCount > limit {
            var discard = byteCount - limit
            while let first = chunks.first, discard >= first.count {
                discard -= first.count
                chunks.removeFirst()
            }
            if discard > 0, let first = chunks.first {
                chunks[0] = Data(first.dropFirst(discard))
            }
            byteCount = limit
            resetRevision += 1
        }
        revision += 1
    }

    var accessibilityText: String {
        let limit = 16 * 1_024
        var remaining = max(0, byteCount - limit)
        var suffix = Data(capacity: min(limit, byteCount))
        for chunk in chunks {
            if remaining >= chunk.count {
                remaining -= chunk.count
                continue
            }
            suffix.append(chunk.dropFirst(remaining))
            remaining = 0
        }
        return String(decoding: suffix, as: UTF8.self)
    }

    private static func chunked(_ data: Data) -> [Data] {
        let size = 64 * 1_024
        return stride(from: 0, to: data.count, by: size).map { offset in
            Data(data[offset..<min(data.count, offset + size)])
        }
    }
}

enum IOSTerminalDirection: CaseIterable, Sendable {
    case up
    case down
    case left
    case right
}

enum IOSTerminalKeyInput {
    static let escape = Data([0x1b])
    static let tab = Data([0x09])
    static let enter = Data([0x0d])

    static func arrow(_ direction: IOSTerminalDirection) -> Data {
        let suffix: UInt8 =
            switch direction {
            case .up: 0x41
            case .down: 0x42
            case .right: 0x43
            case .left: 0x44
            }
        return Data([0x1b, 0x5b, suffix])
    }

    static func function(_ number: Int) -> Data? {
        let sequence: String? =
            switch number {
            case 1: "\u{1b}OP"
            case 2: "\u{1b}OQ"
            case 3: "\u{1b}OR"
            case 4: "\u{1b}OS"
            case 5: "\u{1b}[15~"
            case 6: "\u{1b}[17~"
            case 7: "\u{1b}[18~"
            case 8: "\u{1b}[19~"
            case 9: "\u{1b}[20~"
            case 10: "\u{1b}[21~"
            case 11: "\u{1b}[23~"
            case 12: "\u{1b}[24~"
            default: nil
            }
        return sequence.map { Data($0.utf8) }
    }

    static func controlModified(_ data: Data) -> Data? {
        guard data.count == 1, let byte = data.first else { return nil }
        let value: UInt8? =
            switch byte {
            case 0x40...0x5f: byte & 0x1f
            case 0x61...0x7a: byte & 0x1f
            case 0x20: 0
            case 0x3f: 0x7f
            default: nil
            }
        return value.map { Data([$0]) }
    }
}

#if os(iOS)
    import DieterAPI
    import Observation

    /// SwiftUI adapter for the shared core's terminal surface. Kotlin owns
    /// selection, stream replay, retries, input bounds, and resize coalescing.
    @MainActor
    @Observable
    final class IOSTerminalsModel {
        @ObservationIgnored private unowned let store: IOSStore

        init(store: IOSStore) { self.store = store }

        var machineName: String { store.utilityMachine?.name ?? "Machine" }
        var routeLabel: String { store.machineRouteDescriptions[store.utilityMachineID ?? ""] ?? "" }
        var terminals: [Dieter_V1_Terminal] { store.terminalSlice.terminals }
        var selectedTerminalID: String? {
            store.terminalSlice.selectedID.isEmpty ? nil : store.terminalSlice.selectedID
        }
        var screens: [String: IOSTerminalScreenState] { store.terminalScreens }
        var loading: Bool { store.terminalSlice.loading }
        var streamConnected: Bool { store.terminalSlice.streamConnected }
        var errorMessage: String? {
            get { store.terminalError }
            set { if newValue == nil { store.clearTerminalError() } }
        }
        var selectedTerminal: Dieter_V1_Terminal? {
            terminals.first { $0.id == selectedTerminalID }
        }

        func connect(machineID: String) async {
            await store.bindTerminals(machineID: machineID, active: true)
        }

        func disconnect(clear: Bool = false) async {
            await store.setTerminalsActive(false, clear: clear)
        }

        func refresh() { Task { await store.loadTerminals() } }
        func select(_ id: String) { Task { await store.selectTerminal(id) } }

        func create(name: String, shell: String, workingDirectory: String) async -> Bool {
            await store.createTerminal(name: name, shell: shell, workingDirectory: workingDirectory)
        }

        func rename(id: String, name: String) async { await store.renameTerminal(id: id, name: name) }
        func close(id: String) async { await store.closeTerminal(id: id) }
        func resize(id: String, columns: Int, rows: Int) async {
            await store.resizeTerminal(columns: columns, rows: rows)
        }
        func send(id: String, data: Data) { store.sendTerminalInput(data) }
    }
#endif
