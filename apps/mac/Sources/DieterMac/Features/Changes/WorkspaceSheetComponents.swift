import AppKit
import DieterAPI
import SwiftUI

struct WorkspaceToastView: View {
    let toast: WorkspaceToast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(
                DieterTheme.diffAddition)
            Text(toast.message).font(.system(size: 12, weight: .medium)).foregroundStyle(DieterTheme.text)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 540)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16).frame(height: 40)
        .background(DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DieterTheme.strongBorder))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        .accessibilityIdentifier("workspace-toast")
    }
}

// MARK: - Sheet primitives

struct WorkspaceSheetHeader: View {
    let eyebrow: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 36, height: 36).background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow).font(DieterFont.sectionLabel).tracking(0.5).foregroundStyle(tint)
                Text(title).font(.custom("Sora", size: 19).weight(.semibold)).foregroundStyle(DieterTheme.text)
                if !detail.isEmpty {
                    Text(detail).font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary).fixedSize(
                        horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(DieterTheme.sidebar)
    }
}

struct WorkspaceSheetField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var multiline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            WorkspaceSheetPickerLabel(label)
            if multiline {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(4...8).workspaceSheetInput(minHeight: 92, alignment: .topLeading)
            } else {
                TextField(placeholder, text: $text).workspaceSheetInput(minHeight: 36, alignment: .leading)
            }
        }
    }
}

struct WorkspaceSheetPickerLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(DieterFont.sectionLabel).tracking(0.45).foregroundStyle(DieterTheme.tertiary)
    }
}

struct WorkspaceSheetOptions<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 11) { content() }
            .font(DieterFont.body).toggleStyle(.switch).controlSize(.small)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.border))
    }
}

struct WorkspaceSheetNotice: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(DieterTheme.text)
                Text(detail).font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary).fixedSize(
                    horizontal: false, vertical: true)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.18)))
    }
}

extension View {
    func workspaceSheetInput(minHeight: CGFloat, alignment: Alignment) -> some View {
        textFieldStyle(.plain).font(DieterFont.body).padding(.horizontal, 11).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: alignment)
            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.strongBorder))
    }
}
