import DieterClientAPI
import Testing

@testable import DieterMacKit

/// The channels view model over a scripted core: it folds the channels and
/// settings slices the core sends, its commands carry exactly what the user
/// chose for the view's scope, and refusals show as its error.
@MainActor
struct ChannelsModelTests {
    private func stream(unread: Int32 = 0) -> ClientChannelStreamView {
        .with {
            $0.channel = .with {
                $0.daemonID = "d1"
                $0.projectID = "p1"
            }
            $0.title = "#pricing"
            $0.unread = unread
            $0.rows = [
                .with {
                    $0.id = "m1"; $0.body = "rules.ts is free"; $0.kind = .done; $0.kindLabel = "DONE"
                    $0.author = .with {
                        $0.name = "Fix checkout tests"; $0.initials = "FC"
                    }
                },
                .with {
                    $0.id = "m2"; $0.event = true; $0.body = "Review headers released a.ts for Add tiers"
                },
            ]
            $0.composer = .with {
                $0.canPost = true; $0.placeholder = "Message #pricing"
            }
        }
    }

    @Test func itFoldsTheChannelsAndSettingsTheCoreSends() {
        let core = ScriptedCoreClient()
        let model = ChannelsModel(scope: "test-channels")
        model.attach(core)
        model.attach(core)
        #expect(core.isObserved(.channels, scope: "test-channels"))
        #expect(core.isObserved(.channelSettings))
        #expect(model.stream == nil && model.unread == 0)

        core.emit(.channels, scope: "test-channels") {
            $0.channels = .with {
                $0.unread = 3
                $0.unreadLabel = "3"
                $0.enabled = true
                $0.machines = [
                    .with {
                        $0.daemonID = "d1"; $0.name = "mbp-office"
                        $0.channels = [
                            .with {
                                $0.id = "d1/p1"; $0.projectID = "p1"; $0.name = "pricing"; $0.unread = 3
                            }
                        ]
                    }
                ]
                $0.stream = stream(unread: 3)
            }
        }
        #expect(model.unread == 3)
        #expect(model.slice.machines.first?.channels.first?.name == "pricing")
        #expect(model.stream?.rows.map(\.id) == ["m1", "m2"])

        core.emit(.channelSettings) {
            $0.channelSettings = .with {
                $0.global = true
                $0.projects = [
                    .with {
                        $0.id = "p1"; $0.mode = .off; $0.label = "Off"
                    }
                ]
                $0.boards = [
                    .with {
                        $0.id = "b1"; $0.mode = .inherit; $0.label = "Inherit (Off)"
                    }
                ]
            }
        }
        #expect(model.settings.global)
        #expect(model.projectSetting("p1")?.label == "Off")
        #expect(model.boardSetting("b1")?.label == "Inherit (Off)")
        #expect(model.boardSetting("gone") == nil)
    }

    @Test func commandsCarryTheViewsScopeAndTheUsersChoices() async {
        let core = ScriptedCoreClient()
        let model = ChannelsModel(scope: "test-channels")
        model.attach(core)
        await model.select(daemonID: "d1", projectID: "p1")
        await model.setActive(true)
        let posted = await model.post(body: "rebase first", to: ["c1"], kind: .request, wake: true)
        await model.post(body: "fyi", to: [], kind: .note, wake: true)
        await model.pin("m1", pinned: true)
        await model.release(cardID: "c1", path: "src/a.ts")
        await model.setSetting(scope: .board, id: "b1", mode: .inherit)
        await model.setGlobal(true)
        #expect(posted)

        let commands = core.commands.map(\.channels)
        #expect(commands.allSatisfy { $0.scope == "test-channels" })
        #expect(commands[0].select.daemonID == "d1" && commands[0].select.projectID == "p1")
        #expect(commands[1].active.on)
        #expect(commands[2].post.body == "rebase first" && commands[2].post.toCardIds == ["c1"])
        #expect(commands[2].post.kind == .request && commands[2].post.wake)
        #expect(!commands[3].post.wake, "waking needs direct recipients")
        #expect(commands[4].pin.messageID == "m1" && commands[4].pin.pinned)
        #expect(commands[5].releaseClaim.cardID == "c1" && commands[5].releaseClaim.path == "src/a.ts")
        #expect(commands[6].setSetting.scope == .board && commands[6].setSetting.mode == .inherit)
        #expect(commands[7].setSetting.scope == .global && commands[7].setSetting.mode == .on)
    }

    @Test func markingReadWaitsForUnreadMessagesAndFailuresShow() async {
        let core = ScriptedCoreClient()
        let model = ChannelsModel(scope: "test-channels")
        model.attach(core)
        await model.markRead()
        #expect(core.commands.isEmpty, "nothing is selected")

        core.emit(.channels, scope: "test-channels") { $0.channels = .with { $0.stream = stream(unread: 0) } }
        await model.markRead()
        #expect(core.commands.isEmpty, "nothing is unread")

        core.emit(.channels, scope: "test-channels") { $0.channels = .with { $0.stream = stream(unread: 2) } }
        // The command's reply is the surface after it.
        core.handler = { _ in .with { $0.channels = .with { $0.stream = stream(unread: 0) } } }
        await model.markRead()
        #expect(core.commands.count == 1)
        if case .markRead? = core.commands.last?.channels.action {
        } else {
            Issue.record("the visible end marks the channel read")
        }
        #expect(model.stream?.unread == 0)

        core.handler = { _ in throw CoreFailure(kind: .permanent, message: "agent channels are off") }
        let posted = await model.post(body: "anyone?", to: [], kind: .note, wake: false)
        #expect(!posted)
        #expect(model.errorMessage == "agent channels are off")
        core.handler = { _ in .with { $0.done = ClientDone() } }
        await model.refresh()
        #expect(model.errorMessage == nil, "a command that succeeds clears the failure")
    }

    @Test func theChannelsPaneHasItsOwnWidths() {
        let layout = ChatPaneLayout.channels
        #expect(layout.identifier == "channels")
        #expect(layout.preference == "dieter.channelsPaneWidth")
        #expect(layout.minimumWidth <= layout.defaultWidth && layout.defaultWidth <= layout.maximumWidth)
        #expect(ChatPaneLayout.inbox.identifier == "inbox" && ChatPaneLayout.chats.identifier == "chats")
        #expect(AppSection.channels.rawValue == "Channels")
    }

    @Test func avatarsAndBadgesUseStableColours() {
        #expect(ChannelStyle.harnessSymbol("codex") == "sparkles")
        #expect(ChannelStyle.harnessSymbol("claude-code") == "brain.head.profile")
        #expect(ChannelStyle.harnessSymbol("") == nil)
        #expect(ChannelStyle.avatarColor(3) == ChannelStyle.avatarColor(11))
        #expect(ChannelStyle.time(0).isEmpty)
    }
}
