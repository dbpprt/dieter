import AppKit
import DieterAPI
import DieterShared
import SwiftUI
import UniformTypeIdentifiers

struct LabelsSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = SharedRules.shared.randomLabelColor(exclude: "")
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
                Button("Done") { dismiss() }.buttonStyle(DieterBarButtonStyle())
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
                        .dieterInset(radius: 8)
                        HStack {
                            Text("The instruction is composed with global, project, and board prompts.")
                                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                            Spacer()
                            Button("Create label") { Task { await createLabel() } }
                                .buttonStyle(DieterBarButtonStyle(prominent: true, size: 28))
                                .disabled(
                                    creating || !SharedRules.shared.labelProblem(name: name, color: color).isEmpty)
                        }
                    }
                    .padding(14).dieterTile(radius: 10)
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
        color = SharedRules.shared.randomLabelColor(exclude: color)
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
                    .buttonStyle(DieterBarButtonStyle(shape: .circle, destructive: true, size: 26))
                    .help("Remove \(label.name)")
            }
            LabelColorControl(color: $color)
            Text("AGENT INSTRUCTIONS").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
            TextField("Optional prompt added when this label is assigned…", text: $instructions, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1...4)
                .padding(12).frame(height: 76)
                .dieterInset(radius: 8)
            HStack {
                Text("Applied only to cards carrying this label").font(.caption2).foregroundStyle(DieterTheme.tertiary)
                Spacer()
                Button(saving ? "Saving…" : "Save changes") { Task { await save() } }
                    .buttonStyle(DieterBarButtonStyle(size: 28))
                    .disabled(saving || !SharedRules.shared.labelProblem(name: name, color: color).isEmpty)
            }
        }
        .padding(14).dieterTile(radius: 10)
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
    /// The shared label palette, in the order the core lists it.
    static let swatches = ClientLabelPalette(rules: SharedRules.shared.labelPalette()).swatches

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
            get: {
                Color(hex: color) ?? Color(hex: LabelColorPalette.swatches.first?.hex ?? "") ?? DieterTheme.shellDeep
            },
            set: { if let hex = LabelColorPalette.hex(for: $0) { color = hex } }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("COLOR").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
            ForEach(LabelColorPalette.swatches, id: \.hex) { swatch in
                Button {
                    color = swatch.hex
                } label: {
                    Circle()
                        .fill(Color(hex: swatch.hex) ?? DieterTheme.shellDeep)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().stroke(
                                Color.white.opacity(
                                    color.caseInsensitiveCompare(swatch.hex) == .orderedSame ? 0.9 : 0.18),
                                lineWidth: color.caseInsensitiveCompare(swatch.hex) == .orderedSame ? 2 : 1)
                        )
                        .padding(2)
                }
                .buttonStyle(.plain)
                .help(swatch.name)
                .accessibilityLabel("Use \(swatch.name) label color")
            }
            ColorPicker("Custom label color", selection: pickerColor, supportsOpacity: false)
                .labelsHidden()
                .help("Choose a custom color")
            TextField(LabelColorPalette.swatches.first?.hex ?? "Hex color", text: $color)
                .font(.body.monospaced())
                .frame(width: 88)
                .accessibilityLabel("Label color hex value")
        }
    }
}
