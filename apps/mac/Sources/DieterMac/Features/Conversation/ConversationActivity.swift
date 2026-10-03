import DieterAPI
import DieterShared
import SwiftUI
import UniformTypeIdentifiers

struct TaskPlanView: View {
    let plan: Dieter_V1_TaskPlan
    @State private var expanded = true

    private var tasks: [Dieter_V1_TaskPlanItem] { plan.phases.flatMap(\.tasks) }

    var body: some View {
        let summary = ClientTaskPlanSummary(rules: SharedRules.shared.taskPlanSummary(plan: plan.rulesData))
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").font(.system(size: 11)).foregroundStyle(DieterTheme.shell)
                    Text("Progress").font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(summary.completed) of \(summary.total)").font(.caption2).foregroundStyle(
                        DieterTheme.tertiary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DieterTheme.tertiary)
                }.padding(.horizontal, 12).frame(height: 38)
            }.buttonStyle(.plain)

            if expanded {
                if !plan.explanation.isEmpty {
                    Text(plan.explanation).font(.caption).foregroundStyle(DieterTheme.subtle)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 9)
                }
                ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                    Divider().overlay(DieterTheme.border)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: planIcon(task.status))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(planColor(task.status)).frame(
                                width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.taskTexts.indices.contains(index) ? summary.taskTexts[index] : task.content)
                                .font(.caption).foregroundStyle(
                                    task.status == "pending" ? DieterTheme.subtle : DieterTheme.text
                                )
                                .fixedSize(horizontal: false, vertical: true)
                            if !task.blocker.isEmpty {
                                Text(task.blocker).font(.caption2).foregroundStyle(DieterTheme.coral)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
        }
        .background(DieterTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DieterTheme.border))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planIcon(_ status: String) -> String {
        status == "completed"
            ? "checkmark.circle.fill" : status == "in_progress" ? "circle.dotted.circle.fill" : "circle"
    }
    private func planColor(_ status: String) -> Color {
        status == "completed" ? DieterTheme.eyes : status == "in_progress" ? DieterTheme.primary : DieterTheme.tertiary
    }
}

struct SubagentTimelineGroup: View {
    let agents: [Dieter_V1_Subagent]
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "person.2.fill").font(.system(size: 10)).foregroundStyle(DieterTheme.shell)
                    Text(SharedRules.shared.count(count: Int32(clamping: agents.count), noun: "subagent", plural: ""))
                        .font(.caption.weight(.semibold))
                    Spacer();
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8)).foregroundStyle(
                        DieterTheme.tertiary)
                }
                .padding(.horizontal, 10).frame(height: 31)
                .background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain)
            if expanded {
                VStack(spacing: 7) { ForEach(agents, id: \.id) { SubagentTimelineCard(agent: $0) } }.padding(
                    .leading, 14)
            }
        }
    }
}

/// A delegated agent as the core summarizes it.
private func subagentSummary(_ agent: Dieter_V1_Subagent) -> ClientSubagentSummary {
    ClientSubagentSummary(
        rules: SharedRules.shared.subagentSummary(agent: agent.rulesData, nowMillis: Date.now.epochMillis))
}

struct SubagentTimelineCard: View {
    let agent: Dieter_V1_Subagent
    @State private var expanded = false

    var body: some View {
        let summary = subagentSummary(agent)
        VStack(spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: summary.completed ? "checkmark" : "circle.dotted")
                        .foregroundStyle(runtimeColor(agent.status)).frame(width: 13)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.title)
                            .font(.caption.weight(.semibold)).lineLimit(1)
                        Text(summary.identity).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                    Spacer();
                    Text(agent.status.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(
                        runtimeColor(agent.status))
                    Image(systemName: expanded ? "chevron.up" : "chevron.right").font(.system(size: 8)).foregroundStyle(
                        DieterTheme.tertiary)
                }.padding(11)
            }.buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((summary.narrative + summary.details).enumerated()), id: \.offset) { _, detail in
                        if detail.monospace {
                            CodeBlock(title: detail.label, value: detail.text)
                        } else {
                            Text(detail.text).font(.caption).foregroundStyle(DieterTheme.subtle)
                        }
                    }
                }.padding(.horizontal, 11).padding(.bottom, 11)
            }
        }
        .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct SubagentsView: View {
    @Environment(ConversationContext.self) private var context
    var background: Color = DieterTheme.background
    private var agents: [Dieter_V1_Subagent] { context.conversation?.conversation.subagents ?? [] }
    private var running: Int { agents.filter { subagentSummary($0).active }.count }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 11) {
                HStack {
                    Text(SharedRules.shared.count(count: Int32(clamping: agents.count), noun: "subagent", plural: ""))
                        .font(.headline)
                    if running > 0 {
                        Text("• \(running) running").font(.caption.weight(.semibold)).foregroundStyle(
                            DieterTheme.primary)
                    }
                    Spacer()
                    if running > 0, let card = context.selectedCard {
                        Button {
                            Task { await context.cancel(card) }
                        } label: {
                            Label("Stop all", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered).tint(DieterTheme.coral)
                    }
                }.padding(.bottom, 4)

                if agents.isEmpty {
                    ContentUnavailableView(
                        "No subagents", systemImage: "person.2",
                        description: Text("Delegated work will appear here in real time.")
                    )
                    .padding(.vertical, 40)
                }
                ForEach(agents, id: \.id) { SubagentDetailCard(agent: $0) }
                if !agents.isEmpty {
                    Text("Updates stream while connected").font(.caption2).foregroundStyle(DieterTheme.tertiary)
                        .padding(.top, 3)
                }
            }.padding(18)
        }.background(background)
    }
}

struct SubagentDetailCard: View {
    let agent: Dieter_V1_Subagent

    var body: some View {
        let summary = subagentSummary(agent)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: summary.completed ? "checkmark.circle" : "circle.dotted")
                        .foregroundStyle(runtimeColor(agent.status))
                    Text(summary.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(); Text(summary.elapsed).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                }
                Text(summary.statusLine)
                    .font(.caption).foregroundStyle(DieterTheme.subtle).lineLimit(2)
                if !summary.usageMetrics.isEmpty {
                    Text(summary.usageMetrics.joined(separator: " · ")).font(.caption2)
                        .foregroundStyle(DieterTheme.tertiary)
                }
                if summary.active {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DieterTheme.raised).frame(height: 3)
                            Capsule().fill(DieterTheme.primary).frame(
                                width: max(16, geometry.size.width * max(0, summary.contextFraction)), height: 3)
                        }
                    }.frame(height: 3)
                }
            }.padding(13)
            Divider().overlay(DieterTheme.border)
            HStack {
                Text(summary.agentLabel).font(.caption.weight(.semibold))
                Text(summary.identity).font(.caption2)
                    .foregroundStyle(DieterTheme.tertiary)
                Spacer(); StatusPill(runtime: agent.status)
            }.padding(.horizontal, 13).frame(height: 36)
        }
        .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(
                summary.active ? DieterTheme.primary.opacity(0.5) : .clear))
    }
}
