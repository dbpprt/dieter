import DieterAPI
import Foundation
import Testing
@testable import DieterCore

@Test func statusAliasesDoNotRepeatNotificationsOrCrossMachineIdentity() {
    var transitions = ActivityTransitions()
    var card = Dieter_V1_Card(); card.id = "card"; card.projectID = "project"; card.runtime = "running"
    #expect(transitions.accept([card], endpointID: "A").isEmpty)
    card.runtime = "needs_input"
    #expect(transitions.accept([card], endpointID: "A").count == 1)
    card.runtime = "waiting_for_user"
    #expect(transitions.accept([card], endpointID: "A").isEmpty)
    #expect(transitions.accept([card], endpointID: "B").isEmpty)
    #expect(RuntimeActivity("future_state") == .unknown("future_state"))
}

@Test func historyRetentionKeepsTheRequestedEndAndBoundsEncodedBytes() {
    let messages = (0..<12).map { index in
        var value = Dieter_V1_UiMessage(); value.id = String(index)
        var part = Dieter_V1_MessagePart(); part.text = String(repeating: "x", count: 100)
        value.parts = [part]; return value
    }
    let older = TranscriptRetention.window(messages, keepingEarlier: true, countLimit: 5, byteLimit: 400)
    let newer = TranscriptRetention.window(messages, keepingEarlier: false, countLimit: 5, byteLimit: 400)
    #expect(older.messages.map(\.id) == ["0", "1", "2"])
    #expect(newer.messages.map(\.id) == ["9", "10", "11"])
    #expect(older.removed == 9)
}

@Test func providerOptionsValidateEnumsAndBooleansWithoutDroppingUnknownOptionTypes() {
    var harness = Dieter_V1_Harness(); harness.id = "provider"
    var choice = Dieter_V1_ProviderOption(); choice.id = "mode"; choice.type = "enum"; choice.defaultValue = "safe"
    var safe = Dieter_V1_ProviderOptionChoice(); safe.value = "safe"; choice.choices = [safe]
    var boolean = Dieter_V1_ProviderOption(); boolean.id = "enabled"; boolean.type = "boolean";
    boolean.defaultValue = "false"
    var text = Dieter_V1_ProviderOption(); text.id = "future"; text.type = "future-type"
    harness.options = [choice, boolean, text]
    #expect(
        ProviderOptionValues.resolved(
            for: harness, existing: ["mode": "invalid", "enabled": "TRUE", "future": "retained", "obsolete": "drop"])
            == ["mode": "safe", "enabled": "true", "future": "retained"])
}
