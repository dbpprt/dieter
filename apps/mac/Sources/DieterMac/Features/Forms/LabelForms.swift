import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct LabelsSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = "#7c5cff"
    @State private var instructions = ""
    @State private var pendingDelete: Dieter_V1_Label?
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Board labels").font(.title2.weight(.bold))
                    Text("Labels can add agent instructions to every card that carries them.")
                        .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(20)
            .background(DieterTheme.sidebar)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if (store.selectedBoard?.labels ?? []).isEmpty {
                        ContentUnavailableView(
                            "No labels yet",
                            systemImage: "tag",
                            description: Text("Create one below, then assign it to cards from the board.")
                        )
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }

                    ForEach(store.selectedBoard?.labels ?? [], id: \.id) { label in
                        BoardLabelEditorRow(label: label, requestDelete: { pendingDelete = label })
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("NEW LABEL").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(
                            DieterTheme.tertiary)
                        HStack(spacing: 9) {
                            Circle().fill(Color(hex: color) ?? DieterTheme.shellDeep).frame(width: 10, height: 10)
                            TextField("Label name", text: $name)
                        }
                        LabelColorControl(color: $color)
                        TextField(
                            "Optional prompt added when this label is assigned…", text: $instructions, axis: .vertical
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1...4)
                        .padding(12).frame(height: 76)
                        .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.border))
                        HStack {
                            Text("The instruction is composed with global, project, and board prompts.")
                                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                            Spacer()
                            Button("Create label") { Task { await createLabel() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(
                                    creating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        || Color(hex: color) == nil)
                        }
                    }
                    .padding(14).dieterSurface(radius: 10)
                }
                .padding(18)
            }
            .background(DieterTheme.background)
        }
        .frame(width: 650, height: 620)
        .confirmationDialog(
            "Remove \(pendingDelete?.name ?? "label")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Remove label", role: .destructive) {
                guard let label = pendingDelete else { return }
                pendingDelete = nil
                Task { await store.deleteLabel(id: label.id) }
            }
        } message: {
            Text(
                "This removes the label from the board and every card. The label's agent instructions are removed too.")
        }
    }

    private func createLabel() async {
        creating = true
        await store.createLabel(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            color: color,
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        name = ""
        instructions = ""
        creating = false
    }
}

struct BoardLabelEditorRow: View {
    @Environment(DieterStore.self) private var store
    let label: Dieter_V1_Label
    let requestDelete: () -> Void
    @State private var name: String
    @State private var color: String
    @State private var instructions: String
    @State private var saving = false

    init(label: Dieter_V1_Label, requestDelete: @escaping () -> Void) {
        self.label = label
        self.requestDelete = requestDelete
        _name = State(initialValue: label.name)
        _color = State(initialValue: label.color)
        _instructions = State(initialValue: label.instructions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Circle().fill(Color(hex: color) ?? DieterTheme.shellDeep).frame(width: 10, height: 10)
                TextField("Label name", text: $name)
                Button(role: .destructive, action: requestDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Remove \(label.name)")
            }
            LabelColorControl(color: $color)
            Text("AGENT INSTRUCTIONS").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
            TextField("Optional prompt added when this label is assigned…", text: $instructions, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1...4)
                .padding(12).frame(height: 76)
                .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.border))
            HStack {
                Text("Applied only to cards carrying this label").font(.caption2).foregroundStyle(DieterTheme.tertiary)
                Spacer()
                Button(saving ? "Saving…" : "Save changes") { Task { await save() } }
                    .disabled(
                        saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || Color(hex: color) == nil)
            }
        }
        .padding(14).dieterSurface(radius: 10)
    }

    private func save() async {
        saving = true
        await store.updateLabel(
            id: label.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            color: color,
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        saving = false
    }
}

struct LabelColorPalette {
    static let colors = [
        "#7c5cff", "#3478f6", "#32ade6", "#00a896", "#34c759", "#a3c940",
        "#ffcc00", "#ff9500", "#ff6b35", "#ff3b30", "#e83e8c", "#af52de",
    ]

    static func hex(for color: Color) -> String? {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02x%02x%02x",
            Int((converted.redComponent * 255).rounded()),
            Int((converted.greenComponent * 255).rounded()),
            Int((converted.blueComponent * 255).rounded())
        )
    }
}

struct LabelColorControl: View {
    @Binding var color: String

    private var pickerColor: Binding<Color> {
        Binding(
            get: { Color(hex: color) ?? Color(hex: LabelColorPalette.colors[0])! },
            set: { if let hex = LabelColorPalette.hex(for: $0) { color = hex } }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("COLOR").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
            ForEach(LabelColorPalette.colors, id: \.self) { hex in
                Button {
                    color = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex)!)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().stroke(
                                Color.white.opacity(color.caseInsensitiveCompare(hex) == .orderedSame ? 0.9 : 0.18),
                                lineWidth: color.caseInsensitiveCompare(hex) == .orderedSame ? 2 : 1)
                        )
                        .padding(2)
                }
                .buttonStyle(.plain)
                .help(hex)
                .accessibilityLabel("Use label color \(hex)")
            }
            ColorPicker("Custom label color", selection: pickerColor, supportsOpacity: false)
                .labelsHidden()
                .help("Choose a custom color")
            TextField("#7c5cff", text: $color)
                .font(.body.monospaced())
                .frame(width: 88)
                .accessibilityLabel("Label color hex value")
        }
    }
}
