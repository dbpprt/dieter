import SwiftUI

/// Shared feedback for cold loads, cached refreshes, and recoverable failures.
/// Selection and the label appear immediately; only the spinner is deferred.
struct LoadFeedback: View {
    let title: String
    var error: String? = nil
    var retry: (() -> Void)? = nil
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showActivity = false

    var body: some View {
        HStack(spacing: 9) {
            if error != nil {
                Image(systemName: "exclamationmark.circle").foregroundStyle(DieterTheme.amber)
            } else if showActivity {
                if reduceMotion {
                    Image(systemName: "hourglass")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Text(error ?? title)
                .font(DieterFont.meta)
                .foregroundStyle(DieterTheme.subtle)
                .fixedSize(horizontal: false, vertical: true)
            if error != nil, let retry { Button("Retry", action: retry).controlSize(.small) }
        }
        .padding(compact ? 8 : 20)
        .frame(maxWidth: compact ? nil : .infinity, maxHeight: compact ? nil : .infinity)
        .accessibilityElement(children: .contain)
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            if !Task.isCancelled { showActivity = true }
        }
    }
}
