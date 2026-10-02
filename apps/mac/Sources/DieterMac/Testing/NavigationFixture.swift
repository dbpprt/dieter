#if DIETER_UI_SMOKE
    import DieterAPI
    import DieterShared

    /// The sidebar and chats layout of projects and chats a UI fixture
    /// installs on this Mac only, laid out by the shared core's rules from the
    /// account's saved layout; the core lays out every real workspace itself.
    @MainActor enum NavigationFixture {
        /// The sidebar's projects, as `NavigationSlice.projects` lays them out.
        static func projects(_ slice: ClientNavigationSlice, available: [Dieter_V1_Project])
            -> ClientProjectNavigation
        {
            ClientProjectNavigation(
                rules: SharedRules.shared.sidebarProjects(
                    navigation: slice.rulesData, projects: ClientProjects.with { $0.projects = available }.rulesData))
        }

        /// The chats pane over live `chats`, as SLICE_CHATS lays it out.
        static func chats(
            _ chats: [Dieter_V1_Card], projects: [Dieter_V1_Project], navigation: ClientNavigationSlice, query: String
        ) -> ClientChatsSlice {
            ClientChatsSlice(
                rules: SharedRules.shared.chatList(
                    chats: ClientCards.with { $0.cards = chats }.rulesData,
                    projects: ClientProjects.with { $0.projects = projects }.rulesData,
                    navigation: navigation.rulesData, query: query, archived: false))
        }
    }
#endif
