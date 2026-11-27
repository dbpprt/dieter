import DieterClientAPI
import SwiftUI

/// Settings › Code reviewer: the account's one reviewer setting, which every
/// machine uses when a conversation's agent asks for a review or the user
/// starts one. The core words and checks it; the pickers show the catalog of
/// the machine the form reads and saves on.
struct CodeReviewerSettings: View {
    @Environment(DieterStore.self) private var store

    /// The machine the form edits, as the core picks it from the session's machines.
    private var machine: String? {
        CodeReviewerRules.machine(store.machines.compactMap { store.machineEntry($0) })
    }

    var body: some View {
        SettingsPage { CodeReviewerSettingsForm(machine: machine) }
            .accessibilityIdentifier("code-reviewer-settings")
            .e2eTarget("code-reviewer-settings")
            .task(id: machine) { await store.codeReviewerModel.load(daemonID: machine) }
    }
}

/// The page's panels: the reviewer's agent, depth, limits and instructions,
/// and Save.
struct CodeReviewerSettingsForm: View {
    @Environment(DieterStore.self) private var store
    let machine: String?
    @State private var controls = CodeReviewerControlsMemo()

    private var model: CodeReviewerModel { store.codeReviewerModel }

    var body: some View {
        VStack(spacing: 14) {
            Text(
                "When a conversation has code review on, its agent can ask this reviewer to check its changes. "
                    + "One setting for all your machines."
            )
            .font(.caption).foregroundStyle(DieterTheme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let problem = model.problem {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(problem)
                        .font(.caption).foregroundStyle(DieterTheme.coral)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Retry") { Task { await model.load(daemonID: machine) } }
                        .buttonStyle(DieterBarButtonStyle(size: 24))
                        .disabled(model.loading)
                }
                .accessibilityIdentifier("code-reviewer-error")
                .e2eTarget("code-reviewer-error", text: problem)
            }
            if let draft = model.draft {
                form(draft)
            } else if model.problem == nil {
                SettingsPanel(title: "Reviewer", subtitle: "Reading the reviewer setting…") {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private func form(_ draft: CodeReviewerDraft) -> some View {
        let catalog = store.harnessCatalog(forDaemon: model.daemonID ?? "")
        SettingsPanel(title: "Reviewer", subtitle: draft.status(catalog: catalog)) {
            if catalog.harnesses.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading agents…").font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
            } else {
                AgentPickerFields(controls: controls.controls(draft, catalog: catalog)) { choice in
                    guard let current = model.draft else { return }
                    model.draft = current.choosing(choice, catalog: catalog)
                }
                .frame(maxWidth: 380, alignment: .leading)
                .accessibilityIdentifier("code-reviewer-agent")
            }
        }
        SettingsPanel(title: "Depth") {
            DieterSegmentedPicker(title: "Depth", selection: depth(draft), options: CodeReviewerRules.depths) {
                Text(CodeReviewerRules.depthTitle($0)).e2eTarget("code-reviewer-depth-\($0)")
            }
            .fixedSize()
            .accessibilityIdentifier("code-reviewer-depth")
            Text(CodeReviewerRules.depthDetail(draft.depth))
                .font(.caption).foregroundStyle(DieterTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        SettingsPanel(title: "Limits") {
            limit(
                "Findings per review", value: draft.maxFindings, range: CodeReviewerRules.findings,
                identifier: "code-reviewer-findings"
            ) { $0.maxFindings = $1 }
            Divider().overlay(DieterTheme.border)
            limit(
                "Reviews per task", value: draft.maxRounds, range: CodeReviewerRules.rounds,
                identifier: "code-reviewer-rounds"
            ) { $0.maxRounds = $1 }
            Text("Agents are asked to stop requesting reviews after this many.")
                .font(.caption).foregroundStyle(DieterTheme.tertiary)
        }
        SettingsPanel(title: "Extra instructions", subtitle: "Added to every review.") {
            TextEditor(text: Binding(get: { model.draft?.instructions ?? "" }, set: { model.draft?.instructions = $0 }))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(9)
                .frame(minHeight: 90)
                .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.strongBorder))
                .overlay(alignment: .topLeading) {
                    if draft.instructions.isEmpty {
                        Text("What matters most in your code")
                            .font(.system(size: 12)).foregroundStyle(DieterTheme.tertiary)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Extra instructions")
                .accessibilityIdentifier("code-reviewer-instructions")
                .e2eTarget("code-reviewer-instructions")
        }
        HStack(spacing: 10) {
            if let problem = model.draftProblem {
                Text(problem).font(.caption).foregroundStyle(DieterTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.showsSaved {
                Text("Saved").font(.caption).foregroundStyle(DieterTheme.tertiary)
                    .accessibilityIdentifier("code-reviewer-saved")
                    .e2eTarget("code-reviewer-saved")
            }
            Spacer(minLength: 8)
            if model.saving { ProgressView().controlSize(.small) }
            Button("Save") { Task { await model.save() } }
                .buttonStyle(DieterBarButtonStyle(prominent: true, size: 28))
                .disabled(!model.canSave)
                .accessibilityIdentifier("code-reviewer-save")
                .e2eTarget("code-reviewer-save")
        }
    }

    /// The draft's depth; an empty one shows as the first, the quick default.
    private func depth(_ draft: CodeReviewerDraft) -> Binding<String> {
        Binding(
            get: { draft.depth.isEmpty ? CodeReviewerRules.depths.first ?? "" : draft.depth },
            set: { model.draft?.depth = $0 })
    }

    /// A whole number within `range`, stepped down and up.
    private func limit(
        _ title: String, value: Int, range: ClosedRange<Int>, identifier: String,
        set: @escaping (inout CodeReviewerDraft, Int) -> Void
    ) -> some View {
        let shown = min(max(value, range.lowerBound), range.upperBound)
        return Stepper(
            value: Binding(
                get: { shown },
                set: { next in
                    guard var draft = model.draft else { return }
                    set(&draft, next)
                    model.draft = draft
                }),
            in: range
        ) {
            HStack {
                Text(title)
                Spacer()
                Text("\(shown)").monospacedDigit().font(.system(size: 12, weight: .medium))
                    .accessibilityIdentifier("\(identifier)-value")
            }
        }
        .font(.system(size: 12))
        .accessibilityIdentifier(identifier)
    }
}
