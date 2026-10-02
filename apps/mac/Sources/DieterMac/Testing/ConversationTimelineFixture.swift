#if DIETER_UI_SMOKE
    import DieterAPI
    import DieterShared

    /// Timeline rows for a conversation a UI fixture installs without the
    /// shared core's conversation surface, laid out by the core's rules.
    /// Queued messages are not rows.
    enum ConversationTimelineFixture {
        static func rows(_ messages: [Dieter_V1_UiMessage], queued: Set<String> = [], showReasoning: Bool = false)
            -> [ClientTimelineItem]
        {
            let encoded = ClientTimelineMessages.with { $0.messages = messages }.rulesData
            return ClientTimelineRows(
                rules: SharedRules.shared.timelineRows(
                    messages: encoded, queuedIds: queued.sorted(), showReasoning: showReasoning)
            ).items
        }
    }
#endif
