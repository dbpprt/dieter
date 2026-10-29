import DieterClientAPI
import DieterCore
import SwiftUI

/// The account's Inbox rules: which projects and labels the Inbox shows or
/// hides. The core applies them and syncs them to every device.
struct InboxRulesSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ClientInboxRule?

    var body: some View {
        Group {
            if let rule = editing {
                InboxRuleEditor(rule: rule) { editing = nil }
            } else {
                list
            }
        }
        .frame(width: 540, height: 560)
    }

    private var list: some View {
        let rules = store.navigation.inboxRules
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Inbox rules").font(.title2.weight(.semibold))
                    Text("Show or hide conversations by project and label. Rules sync to all your devices.")
                        .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 10)
            if rules.isEmpty {
                ContentUnavailableView(
                    "No rules", systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("The Inbox shows every conversation.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rules, id: \.id) { rule in
                    HStack(spacing: 10) {
                        Toggle(
                            "Enabled",
                            isOn: Binding(
                                get: { rule.enabled },
                                set: { value in
                                    var next = rule
                                    next.enabled = value
                                    store.saveInboxRule(next)
                                })
                        )
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .accessibilityIdentifier("inbox.rule.enabled.\(rule.id)")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name.isEmpty ? (rule.hide ? "Hide" : "Show only") : rule.name)
                                .font(.system(size: 13, weight: .semibold))
                            Text(summary(rule)).font(.caption).foregroundStyle(DieterTheme.tertiary)
                                .lineLimit(3)
                        }
                        .opacity(rule.enabled ? 1 : 0.55)
                        Spacer()
                        Button("Edit") { editing = rule }
                            .buttonStyle(DieterBarButtonStyle(size: 26))
                            .accessibilityIdentifier("inbox.rule.edit.\(rule.id)")
                        Button(role: .destructive) {
                            store.deleteInboxRule(rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(DieterBarButtonStyle(shape: .circle, destructive: true, size: 26))
                        .help("Delete this rule")
                        .accessibilityIdentifier("inbox.rule.delete.\(rule.id)")
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
            Text(
                "A conversation that matches a hiding rule is left out. While any showing rule is on, the Inbox lists only conversations that match one."
            )
            .font(.caption2).foregroundStyle(DieterTheme.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 8)
            HStack(spacing: 10) {
                Button("Add rule", systemImage: "plus") {
                    var rule = ClientInboxRule()
                    rule.hide = true
                    rule.enabled = true
                    editing = rule
                }
                .buttonStyle(DieterBarButtonStyle(size: 28))
                .accessibilityIdentifier("inbox.rule.add").e2eTarget("inbox.rule.add")
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(DieterBarButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("inbox.rules.done")
            }
            .padding(20)
        }
    }

    private func summary(_ rule: ClientInboxRule) -> String {
        InboxRuleLabels.summary(rule, store: store)
    }
}

enum InboxRuleLabels {
    /// What `rule` does in words, as the core words it; an unknown project or label reads "Unknown".
    @MainActor
    static func summary(_ rule: ClientInboxRule, store: DieterStore) -> String {
        let catalog = store.inboxRuleCatalog
        let projects = catalog.projectNames
        let labels = catalog.labelNames
        return SharedRules.shared.inboxRuleSummary(
            hide: rule.hide, matchAll: rule.matchAll,
            projectNames: rule.projectIds.map { projects[$0] ?? "Unknown" },
            labelNames: rule.labelIds.map { labels[$0] ?? "Unknown" }
        ) + (rule.enabled ? "" : " (off)")
    }
}

private struct InboxRuleEditor: View {
    @Environment(DieterStore.self) private var store
    let onClose: () -> Void
    private let original: ClientInboxRule
    @State private var name: String
    @State private var hide: Bool
    @State private var matchAll: Bool
    @State private var enabled: Bool
    @State private var projectIDs: Set<String>
    @State private var labelIDs: Set<String>

    init(rule: ClientInboxRule, onClose: @escaping () -> Void) {
        original = rule
        self.onClose = onClose
        _name = State(initialValue: rule.name)
        _hide = State(initialValue: rule.hide)
        _matchAll = State(initialValue: rule.matchAll)
        _enabled = State(initialValue: rule.enabled)
        _projectIDs = State(initialValue: Set(rule.projectIds))
        _labelIDs = State(initialValue: Set(rule.labelIds))
    }

    var body: some View {
        let catalog = store.inboxRuleCatalog
        VStack(spacing: 0) {
            HStack {
                Text(original.id.isEmpty ? "New rule" : "Edit rule").font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 4)
            Form {
                Section {
                    TextField("Name (optional)", text: $name)
                    Picker("Effect", selection: $hide) {
                        Text("Hide").tag(true)
                        Text("Show only").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("inbox.rule.effect")
                    Toggle("On", isOn: $enabled)
                }
                Section("Projects") {
                    ForEach(catalog.projects) { project in
                        Toggle(project.name, isOn: membership($projectIDs, project.id))
                            .accessibilityIdentifier("inbox.rule.project.\(project.id)")
                    }
                }
                ForEach(catalog.labelGroups) { group in
                    Section("Labels · \(group.title)") {
                        ForEach(group.labels) { label in
                            Toggle(isOn: membership($labelIDs, label.id)) {
                                HStack(spacing: 7) {
                                    Circle().fill(Color(hex: label.color) ?? DieterTheme.shellDeep)
                                        .frame(width: 8, height: 8)
                                    Text(label.name)
                                }
                            }
                            .accessibilityIdentifier("inbox.rule.label.\(label.id)")
                        }
                    }
                }
                if !projectIDs.isEmpty && !labelIDs.isEmpty {
                    Section("A conversation matches when") {
                        Picker("Match", selection: $matchAll) {
                            Text("Either matches").tag(false)
                            Text("Both match").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            HStack(spacing: 10) {
                Button("Cancel", action: onClose)
                    .buttonStyle(DieterBarButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(DieterBarButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(projectIDs.isEmpty && labelIDs.isEmpty)
                    .accessibilityIdentifier("inbox.rule.save").e2eTarget("inbox.rule.save")
            }
            .padding(20)
        }
    }

    private func membership(_ set: Binding<Set<String>>, _ id: String) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { on in
                if on { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
            })
    }

    private func save() {
        var rule = original
        rule.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.hide = hide
        rule.matchAll = matchAll
        rule.enabled = enabled
        rule.projectIds = projectIDs.sorted()
        rule.labelIds = labelIDs.sorted()
        store.saveInboxRule(rule)
        onClose()
    }
}
