import DieterAPI
import Foundation

/// Admission happens synchronously on the UI actor, before any task is created.
/// A stalled RPC cannot accumulate an unbounded actor mailbox or input buffer.
@MainActor final class TerminalInputForwarder {
    struct Key: Hashable { let endpointID: String; let terminalID: String }
    private final class Pump {
        let client: any TerminalInputRPC
        let id = UUID()
        var pending = Data()
        var inFlightBytes = 0
        var task: Task<Void, Never>?
        init(client: any TerminalInputRPC) { self.client = client }
    }
    private var pumps: [Key: Pump] = [:]
    let byteLimit: Int
    let sessionLimit: Int
    var pendingByteCount: Int { pumps.values.reduce(0) { $0 + $1.pending.count + $1.inFlightBytes } }

    init(byteLimit: Int = 1_024 * 1_024, sessionLimit: Int = 32) {
        self.byteLimit = max(1, byteLimit); self.sessionLimit = max(1, sessionLimit)
    }

    func enqueue(
        endpointID: String, id: String, data: Data, rpc: any TerminalInputRPC,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        guard !data.isEmpty else { return }
        let key = Key(endpointID: endpointID, terminalID: id)
        if let previous = pumps[key], previous.client !== rpc {
            previous.task?.cancel(); pumps.removeValue(forKey: key)
        }
        guard data.count <= byteLimit - pendingByteCount,
            pumps[key] != nil || pumps.count < sessionLimit
        else {
            onFailure(
                "The terminal is not accepting input quickly enough. This input was not queued; wait before typing or pasting again."
            )
            return
        }
        let pump = pumps[key] ?? Pump(client: rpc)
        pumps[key] = pump
        pump.pending.append(data)
        guard pump.task == nil else { return }
        pump.task = Task { [weak self, weak pump] in
            guard let self, let pump else { return }
            defer { if self.pumps[key] === pump { self.pumps.removeValue(forKey: key) } }
            do {
                try await DieterTaskSleep.milliseconds(12)
                while !Task.isCancelled, self.pumps[key] === pump, !pump.pending.isEmpty {
                    let count = min(pump.pending.count, 64 * 1_024)
                    let chunk = Data(pump.pending.prefix(count))
                    pump.pending.removeFirst(count)
                    pump.inFlightBytes = count
                    _ = try await rpc.writeTerminal(id: id, data: chunk)
                    pump.inFlightBytes = 0
                }
            } catch {
                guard !Task.isCancelled, self.pumps[key] === pump else { return }
                // Delivery may already have happened. Never replay ambiguous input.
                onFailure("\(DieterRPCFailure.message(for: error)). Unconfirmed input was not resent.")
            }
        }
    }

    func suspend() {
        for pump in pumps.values { pump.task?.cancel() }
        pumps.removeAll()
    }
}
