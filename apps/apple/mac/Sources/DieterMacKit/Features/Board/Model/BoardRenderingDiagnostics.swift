/// Opt-in counters for isolated native interaction measurements. They never
/// publish observable state or retain cards, views, transcripts or credentials.
@MainActor
enum BoardRenderingDiagnostics {
    enum Event: String, CaseIterable {
        case tableCreated, fullReload, reloadedRows, rowConfigured, updatedRows, rowStructureChange
        case heightMeasured, heightTransaction, widthChanged, overlayUpdated, cardBody
        case chatListBody, chatRowBody
    }

    #if DEBUG
        private(set) static var readyConversationID: String?
        private static var recording = false
        private static var counts: [Event: Int] = [:]

        static func start() {
            readyConversationID = nil
            counts.removeAll(keepingCapacity: true)
            recording = true
        }

        static func stop() -> [String: Int] {
            recording = false
            return Dictionary(uniqueKeysWithValues: Event.allCases.map { ($0.rawValue, counts[$0, default: 0]) })
        }
    #endif

    static func recordConversationReady(_ id: String, ready: Bool) {
        #if DEBUG
            guard recording else { return }
            readyConversationID = ready ? id : nil
        #endif
    }

    static func record(_ event: Event, count: Int = 1) {
        #if DEBUG
            guard recording else { return }
            counts[event, default: 0] += count
        #endif
    }
}
