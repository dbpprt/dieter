import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct TaskPlanView: View {
    let plan: Dieter_V1_TaskPlan
    @State private var expanded = true

    private var tasks: [Dieter_V1_TaskPlanItem] { plan.phases.flatMap(\.tasks) }
    private var completed: Int { tasks.filter { $0.status == "completed" }.count }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").font(.system(size: 11)).foregroundStyle(DieterTheme.shell)
                    Text("Progress").font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(completed) of \(tasks.count)").font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DieterTheme.tertiary)
                }.padding(.horizontal, 12).frame(height: 38)
            }.buttonStyle(.plain)

            if expanded {
                if !plan.explanation.isEmpty {
                    Text(plan.explanation).font(.caption).foregroundStyle(DieterTheme.subtle)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 9)
                }
                ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in
                    Divider().overlay(DieterTheme.border)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: planIcon(task.status))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(planColor(task.status)).frame(
                                width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                task.status == "in_progress" && !task.activeForm.isEmpty
                                    ? task.activeForm : task.content
                            )
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
                    Text("\(agents.count) subagent\(agents.count == 1 ? "" : "s")").font(.caption.weight(.semibold))
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

struct SubagentTimelineCard: View {
    let agent: Dieter_V1_Subagent
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: agent.status == "completed" ? "checkmark" : "circle.dotted")
                        .foregroundStyle(runtimeColor(agent.status)).frame(width: 13)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name.isEmpty ? (agent.agentType.isEmpty ? "Subagent" : agent.agentType) : agent.name)
                            .font(.caption.weight(.semibold)).lineLimit(1)
                        Text([agent.provider, agent.model].filter { !$0.isEmpty }.joined(separator: "/")).font(
                            .caption2
                        ).foregroundStyle(DieterTheme.tertiary)
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
                    Text(agent.assignment.isEmpty ? agent.task : agent.assignment).font(.caption).foregroundStyle(
                        DieterTheme.subtle)
                    if !agent.recentOutput.isEmpty {
                        CodeBlock(title: "Recent output", value: agent.recentOutput.joined(separator: "\n"))
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
    private var running: Int { agents.filter { ["running", "pending"].contains($0.status) }.count }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 11) {
                HStack {
                    Text("\(agents.count) subagent\(agents.count == 1 ? "" : "s")").font(.headline)
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
    private var fraction: Double {
        guard agent.contextWindow > 0 else { return agent.status == "completed" ? 1 : 0 }
        return min(1, Double(agent.contextTokens) / Double(agent.contextWindow))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: agent.status == "completed" ? "checkmark.circle" : "circle.dotted")
                        .foregroundStyle(runtimeColor(agent.status))
                    Text(agent.name.isEmpty ? (agent.agentType.isEmpty ? "Subagent" : agent.agentType) : agent.name)
                        .font(.subheadline.weight(.semibold))
                    Spacer(); Text(duration(agent.durationMs)).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                }
                Text(
                    agent.activity.isEmpty ? (agent.assignment.isEmpty ? agent.task : agent.assignment) : agent.activity
                )
                .font(.caption).foregroundStyle(DieterTheme.subtle).lineLimit(2)
                let usage = SubagentUsagePresentation.resolve(
                    tokens: agent.tokens, contextTokens: agent.contextTokens, contextWindow: agent.contextWindow)
                if !usage.metrics.isEmpty {
                    Text(usage.metrics.joined(separator: " · ")).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                }
                if agent.status == "running" {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DieterTheme.raised).frame(height: 3)
                            Capsule().fill(DieterTheme.primary).frame(
                                width: max(16, geometry.size.width * fraction), height: 3)
                        }
                    }.frame(height: 3)
                }
            }.padding(13)
            Divider().overlay(DieterTheme.border)
            HStack {
                Text(agent.name.isEmpty ? String(agent.id.prefix(8)) : agent.name).font(.caption.weight(.semibold))
                Text([agent.provider, agent.model].filter { !$0.isEmpty }.joined(separator: "/")).font(.caption2)
                    .foregroundStyle(DieterTheme.tertiary)
                Spacer(); StatusPill(text: agent.status, color: runtimeColor(agent.status))
            }.padding(.horizontal, 13).frame(height: 36)
        }
        .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(
                agent.status == "running" ? DieterTheme.primary.opacity(0.5) : .clear))
    }

    private func duration(_ milliseconds: Int64) -> String {
        guard milliseconds > 0 else { return "" }
        let seconds = milliseconds / 1_000
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}
