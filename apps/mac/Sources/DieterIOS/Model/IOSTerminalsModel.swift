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
    import DieterClient
    import DieterCore
    import GRPCCore
    import Observation

    /// A bounded input pump admits bytes on the main actor before starting an
    /// RPC. A failed or disconnected write is never replayed because delivery
    /// may already have happened on the daemon.
    @MainActor
    private final class IOSTerminalInputPump {
        private var pending = Data()
        private var inFlightBytes = 0
        private var terminalID = ""
        private weak var rpc: DieterRPC?
        private var task: Task<Void, Never>?
        private let byteLimit = 1_024 * 1_024

        func enqueue(
            id: String,
            data: Data,
            rpc: DieterRPC,
            failure: @escaping @MainActor (String) -> Void
        ) {
            guard !data.isEmpty else { return }
            if terminalID != id || self.rpc !== rpc {
                suspend()
                terminalID = id
                self.rpc = rpc
            }
            guard data.count <= byteLimit - pending.count - inFlightBytes else {
                failure("The terminal is not accepting input quickly enough. Wait before typing or pasting again.")
                return
            }
            pending.append(data)
            guard task == nil else { return }
            task = Task { [weak self, weak rpc] in
                guard let self, let rpc else { return }
                defer { self.task = nil }
                do {
                    try await DieterTaskSleep.milliseconds(12)
                    while !Task.isCancelled, self.rpc === rpc, self.terminalID == id, !self.pending.isEmpty {
                        let count = min(self.pending.count, 64 * 1_024)
                        let chunk = Data(self.pending.prefix(count))
                        self.pending.removeFirst(count)
                        self.inFlightBytes = count
                        _ = try await rpc.writeTerminal(id: id, data: chunk)
                        self.inFlightBytes = 0
                    }
                } catch {
                    guard !Task.isCancelled, self.rpc === rpc, self.terminalID == id else { return }
                    self.pending.removeAll(keepingCapacity: false)
                    self.inFlightBytes = 0
                    failure("\(DieterRPCFailure.message(for: error)). Unconfirmed input was not resent.")
                }
            }
        }

        func suspend() {
            task?.cancel()
            task = nil
            pending.removeAll(keepingCapacity: false)
            inFlightBytes = 0
            terminalID = ""
            rpc = nil
        }
    }

    @MainActor
    @Observable
    final class IOSTerminalsModel {
        private(set) var machineName = "Machine"
        private(set) var routeLabel = ""
        private(set) var terminals: [Dieter_V1_Terminal] = []
        private(set) var selectedTerminalID: String?
        private(set) var screens: [String: IOSTerminalScreenState] = [:]
        private(set) var loading = false
        private(set) var streamConnected = false
        var errorMessage: String?

        var selectedTerminal: Dieter_V1_Terminal? {
            terminals.first { $0.id == selectedTerminalID }
        }

        @ObservationIgnored private var openConnection: (@MainActor () async throws -> DataPlaneConnection)?
        @ObservationIgnored private var connection: DataPlaneConnection?
        @ObservationIgnored private var loadTask: Task<Void, Never>?
        @ObservationIgnored private var watchTask: Task<Void, Never>?
        @ObservationIgnored private var generation: UInt64 = 0
        @ObservationIgnored private var sequences: [String: UInt64] = [:]
        @ObservationIgnored private let inputPump = IOSTerminalInputPump()

        func connect(
            machineName: String,
            open: @escaping @MainActor () async throws -> DataPlaneConnection
        ) {
            disconnect(clear: true)
            self.machineName = machineName
            openConnection = open
            let token = generation
            loadTask = Task { [weak self] in await self?.load(generation: token) }
        }

        func disconnect(clear: Bool = false) {
            generation &+= 1
            loadTask?.cancel()
            loadTask = nil
            watchTask?.cancel()
            watchTask = nil
            inputPump.suspend()
            connection?.shutdown()
            connection = nil
            streamConnected = false
            routeLabel = ""
            if clear {
                terminals = []
                selectedTerminalID = nil
                screens = [:]
                sequences = [:]
                errorMessage = nil
            }
        }

        func refresh() {
            let token = generation
            loadTask?.cancel()
            loadTask = Task { [weak self] in await self?.load(generation: token, replaceConnection: true) }
        }

        func select(_ id: String) {
            guard terminals.contains(where: { $0.id == id }), selectedTerminalID != id else { return }
            selectedTerminalID = id
            inputPump.suspend()
            startWatch()
        }

        func create(name: String, shell: String, workingDirectory: String) async -> Bool {
            do {
                let rpc = try await currentRPC()
                var request = Dieter_V1_CreateTerminalRequest()
                request.machineHome = true
                request.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                request.shell = shell
                request.workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                request.columns = 80
                request.rows = 24
                let terminal = try await rpc.createTerminal(request)
                upsert(terminal)
                selectedTerminalID = terminal.id
                sequences[terminal.id] = 0
                screens[terminal.id] = IOSTerminalScreenState()
                startWatch()
                return true
            } catch {
                report(error)
                return false
            }
        }

        func rename(id: String, name: String) async {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            do { upsert(try await currentRPC().renameTerminal(id: id, name: name)) } catch { report(error) }
        }

        func close(id: String) async {
            do {
                try await currentRPC().closeTerminal(id: id)
                terminals.removeAll { $0.id == id }
                screens.removeValue(forKey: id)
                sequences.removeValue(forKey: id)
                if selectedTerminalID == id {
                    selectedTerminalID = terminals.first?.id
                    inputPump.suspend()
                    startWatch()
                }
            } catch { report(error) }
        }

        func resize(id: String, columns: Int, rows: Int) async {
            guard columns >= 2, rows >= 1,
                terminals.first(where: { $0.id == id })?.status == "running"
            else { return }
            do {
                upsert(try await currentRPC().resizeTerminal(id: id, columns: columns, rows: rows))
            } catch  where DieterRPCFailure.isCancellation(error) {
            } catch { report(error) }
        }

        func send(id: String, data: Data) {
            guard let rpc = connection?.rpc,
                terminals.first(where: { $0.id == id })?.status == "running"
            else { return }
            inputPump.enqueue(id: id, data: data, rpc: rpc) { [weak self] message in
                self?.errorMessage = message
            }
        }

        private func load(generation token: UInt64, replaceConnection: Bool = false) async {
            guard token == generation else { return }
            loading = true
            defer { if token == generation { loading = false; loadTask = nil } }
            do {
                if replaceConnection { invalidateConnection() }
                let response = try await currentRPC().terminals(projectID: "", cardID: "")
                guard token == generation else { return }
                terminals = response.terminals.sorted(by: Self.terminalOrder)
                let live = Set(terminals.map(\.id))
                screens = screens.filter { live.contains($0.key) }
                sequences = sequences.filter { live.contains($0.key) }
                if selectedTerminalID.flatMap({ id in terminals.first(where: { $0.id == id }) }) == nil {
                    selectedTerminalID = terminals.first?.id
                }
                errorMessage = nil
                startWatch()
            } catch  where DieterRPCFailure.isCancellation(error) {
            } catch {
                guard token == generation else { return }
                report(error)
            }
        }

        private func startWatch() {
            watchTask?.cancel()
            watchTask = nil
            streamConnected = false
            guard let id = selectedTerminalID,
                terminals.contains(where: { $0.id == id })
            else { return }
            let token = generation
            watchTask = Task { [weak self] in
                guard let self else { return }
                var delay = 0.5
                while !Task.isCancelled, token == self.generation, self.selectedTerminalID == id {
                    do {
                        let rpc = try await self.currentRPC()
                        self.streamConnected = true
                        try await rpc.watchTerminal(id: id, after: self.sequences[id] ?? 0) { [weak self] frame in
                            await self?.accept(frame, terminalID: id, generation: token)
                        }
                        guard !Task.isCancelled else { return }
                        self.streamConnected = false
                    } catch  where DieterRPCFailure.isCancellation(error) {
                        return
                    } catch {
                        guard token == self.generation, self.selectedTerminalID == id else { return }
                        self.streamConnected = false
                        if let rpcError = error as? RPCError, rpcError.code == .notFound {
                            self.terminals.removeAll { $0.id == id }
                            self.selectedTerminalID = self.terminals.first?.id
                            return
                        }
                        self.invalidateConnection()
                    }
                    try? await DieterTaskSleep.seconds(delay)
                    delay = min(5, delay * 1.8)
                }
            }
        }

        private func accept(
            _ frame: Dieter_V1_TerminalFrame,
            terminalID: String,
            generation token: UInt64
        ) {
            guard token == generation, selectedTerminalID == terminalID,
                frame.hasTerminal, frame.terminal.id == terminalID
            else { return }
            upsert(frame.terminal)
            sequences[terminalID] = max(sequences[terminalID] ?? 0, frame.sequence)
            if frame.screenReset || !frame.data.isEmpty {
                var screen = screens[terminalID] ?? IOSTerminalScreenState()
                screen.apply(data: frame.data, reset: frame.screenReset)
                screens[terminalID] = screen
            }
            streamConnected = true
        }

        private func currentRPC() async throws -> DieterRPC {
            if let rpc = connection?.rpc { return rpc }
            guard let openConnection else {
                throw NSError(
                    domain: "DieterTerminals", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Choose a connected machine."])
            }
            let token = generation
            let plane = try await openConnection()
            guard token == generation else {
                plane.shutdown()
                throw CancellationError()
            }
            connection = plane
            routeLabel = plane.connection.route == .local ? "Direct TLS" : plane.connection.route.rawValue
            return plane.rpc
        }

        private func invalidateConnection() {
            inputPump.suspend()
            connection?.shutdown()
            connection = nil
            routeLabel = ""
        }

        private func upsert(_ terminal: Dieter_V1_Terminal) {
            if let index = terminals.firstIndex(where: { $0.id == terminal.id }) {
                terminals[index] = terminal
            } else {
                terminals.append(terminal)
            }
            terminals.sort(by: Self.terminalOrder)
        }

        private func report(_ error: Error) {
            guard !DieterRPCFailure.isCancellation(error) else { return }
            errorMessage = DieterRPCFailure.message(for: error)
        }

        private static func terminalOrder(_ left: Dieter_V1_Terminal, _ right: Dieter_V1_Terminal) -> Bool {
            if left.createdAt == right.createdAt { return left.id < right.id }
            return left.createdAt < right.createdAt
        }
    }
#endif
