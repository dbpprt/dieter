import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct TurnFailureBanner: View {
    let failure: ConversationTurnFailure
    let retrying: Bool
    let onViewLog: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Turn failed")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(DieterTheme.text)
                    Text("Turn failed — \(failure.summary)")
                        .font(.callout)
                        .foregroundStyle(DieterTheme.coral.opacity(0.9))
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Image(systemName: "xmark.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DieterTheme.coral)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 10) {
                Label("Failed", systemImage: "circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DieterTheme.coral)
                    .padding(.horizontal, 11)
                    .frame(height: 29)
                    .background(DieterTheme.coral.opacity(0.13), in: Capsule())
                Spacer(minLength: 10)
                Button("View log", action: onViewLog)
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(DieterTheme.primary)
                    .accessibilityIdentifier("conversation.failure.view-log")
                    .smokeTarget("conversation.failure.view-log")
                Button(action: onRetry) {
                    HStack(spacing: 6) {
                        if retrying { ProgressView().controlSize(.mini) }
                        Text(retrying ? "Retry queued…" : "Retry turn")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DieterTheme.elevated)
                .foregroundStyle(DieterTheme.text)
                .disabled(retrying || failure.retryParts.isEmpty)
                .accessibilityIdentifier("conversation.failure.retry")
            }
        }
        .padding(16)
        .background(DieterTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DieterTheme.coral.opacity(0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.turn-failure")
    }
}

struct CreationFailureBanner: View {
    let failure: String
    let onRetry: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Conversation needs attention")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(DieterTheme.text)
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(DieterTheme.coral.opacity(0.9))
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DieterTheme.coral)
                    .accessibilityHidden(true)
            }
            Text(
                "Your request is saved. Resolve the error and retry, or discard the pending request."
            )
            .font(.caption)
            .foregroundStyle(DieterTheme.tertiary)
            HStack(spacing: 10) {
                Label("Creation failed", systemImage: "circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DieterTheme.coral)
                    .padding(.horizontal, 11)
                    .frame(height: 29)
                    .background(DieterTheme.coral.opacity(0.13), in: Capsule())
                Spacer(minLength: 10)
                Button("Discard", role: .destructive, action: onDiscard)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("conversation.creation-failure.discard")
                Button("Retry creation", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(DieterTheme.elevated)
                    .foregroundStyle(DieterTheme.text)
                    .accessibilityIdentifier("conversation.creation-failure.retry")
            }
        }
        .padding(16)
        .background(DieterTheme.coral.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DieterTheme.coral.opacity(0.45)))
    }
}

struct TurnFailureLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let log: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Turn failure log").font(.title3.weight(.semibold))
                    Text("Complete output captured from the local harness worker.")
                        .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("conversation.failure.done")
                    .smokeTarget("conversation.failure.done")
            }
            ScrollView([.horizontal, .vertical]) {
                Text(log)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DieterTheme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(DieterTheme.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DieterTheme.border))
            HStack {
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log, forType: .string)
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 440)
        .background(DieterTheme.surface)
        .accessibilityIdentifier("conversation.failure.log-sheet")
        .smokeTarget("conversation.failure.log-sheet")
    }
}
