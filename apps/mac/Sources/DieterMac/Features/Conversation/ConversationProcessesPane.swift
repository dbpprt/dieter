import DieterAPI
import SwiftUI

struct ConversationProcessesPane: View {
    @Bindable var model: ConversationProcessesModel
    let active: Bool

    var body: some View {
        if active {
            VStack(spacing: 0) {
                HStack {
                    Text("Processes").font(.headline)
                    Text("\(model.processes.filter { $0.status == "running" }.count) running")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless).help("Refresh processes").accessibilityLabel("Refresh processes")
                    .disabled(model.loading || !model.connected)
                }.padding(12)
                Divider()
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.secondary).padding(12) }
                if model.processes.isEmpty {
                    ContentUnavailableView(
                        "No background processes", systemImage: "gearshape.2",
                        description: Text(
                            "Ask the agent to start a dev server, build, or test in the background. Its state and output will appear here."
                        ))
                } else {
                    HSplitView {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 3) {
                                ForEach(model.processes, id: \.id) { process in
                                    Button {
                                        model.select(process.id)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            HStack(spacing: 6) {
                                                Circle().fill(
                                                    process.status == "running" ? Color.green : Color.secondary
                                                )
                                                .frame(width: 6, height: 6)
                                                Text(process.name).font(.callout.weight(.medium)).lineLimit(1)
                                            }
                                            Text(status(process)).font(.caption).foregroundStyle(.secondary)
                                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(
                                                model.selectedID == process.id ? Color.primary.opacity(0.08) : .clear,
                                                in: RoundedRectangle(cornerRadius: 7)
                                            )
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                        .accessibilityIdentifier("conversation.content.process.\(process.id)")
                                }
                            }.padding(6)
                        }.frame(minWidth: 140, idealWidth: 180, maxWidth: 240)
                        output.frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .accessibilityIdentifier("conversation.content.processes")
            .smokeTarget("conversation.content.processes")
        } else {
            Color.clear
        }
    }

    @ViewBuilder private var output: some View {
        if let process = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(process.argv.joined(separator: " ")).font(.system(.caption, design: .monospaced))
                            .lineLimit(2).textSelection(.enabled)
                        Text("\(status(process)) · PID \(process.pid)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Stop", systemImage: "stop.fill") { Task { await model.stopSelected() } }
                        .controlSize(.small).disabled(process.status != "running" || model.stopping || !model.connected)
                        .accessibilityIdentifier("conversation.content.processes.stop")
                        .smokeTarget("conversation.content.processes.stop")
                }.padding(12)
                Divider()
                if model.outputTruncated {
                    Text("Showing recent output. Older output was omitted to keep this view responsive.")
                        .font(.caption).foregroundStyle(.secondary).padding(10)
                }
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 16) {
                        stream("Standard output", data: model.stdout, identifier: "stdout")
                        stream("Standard error", data: model.stderr, identifier: "stderr")
                        if model.stdout.isEmpty && model.stderr.isEmpty {
                            Text(process.status == "running" ? "Waiting for output…" : "No output")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !process.error.isEmpty { Text(process.error).font(.caption).foregroundStyle(.red) }
                    }.padding(12)
                }
                // A two-axis scroll view otherwise centers a short document
                // inside its viewport. Logs always begin at the top-left.
                .defaultScrollAnchor(.topLeading, for: .alignment)
                .defaultScrollAnchor(.topLeading, for: .initialOffset)
                .smokeTarget("conversation.content.processes.output-viewport")
            }.help(process.workingDirectory)
        } else {
            Text("Select a process").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func stream(_ title: String, data: Data, identifier: String) -> some View {
        if !data.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .smokeTarget("conversation.content.processes.\(identifier)-heading")
                Text(String(decoding: data, as: UTF8.self)).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
            }
        }
    }

    private func status(_ process: Dieter_V1_Execution) -> String {
        if process.hasExitCode { return "\(process.status.capitalized) · exit \(process.exitCode)" }
        return process.status.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
