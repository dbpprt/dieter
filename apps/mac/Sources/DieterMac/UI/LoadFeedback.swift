import SwiftUI

/// Shared feedback for cold loads, cached refreshes, and recoverable failures.
/// Keep this view synchronous: short reads can remove it during the same display
/// cycle, so an attached delayed task would be canceled while SwiftUI tears down
/// the view hierarchy.
struct LoadFeedback: View {
    let title: String
    var error: String? = nil
    var retry: (() -> Void)? = nil
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 9) {
            if error != nil {
                Image(systemName: "exclamationmark.circle").foregroundStyle(DieterTheme.amber)
            } else {
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
    }
}
