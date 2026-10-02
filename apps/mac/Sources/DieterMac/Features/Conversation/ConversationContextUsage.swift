import DieterAPI
import DieterShared
import SwiftUI

/// How much of the model's context window the conversation used at its
/// latest reported step, as the core reads it.
struct ContextUsageIndicator: View {
    let state: ClientConversationState

    private var fraction: Double { Double(state.contextPercent) / 100 }

    var body: some View {
        ZStack {
            Circle().stroke(DieterTheme.raised, lineWidth: 3)
            Circle().trim(from: 0, to: fraction)
                .stroke(
                    state.contextNearLimit ? DieterTheme.amber : DieterTheme.shell,
                    style: .init(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(state.contextPercent)").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(
                DieterTheme.subtle)
        }
        .frame(width: 28, height: 28)
        .help(
            "Context used: \(SharedRules.shared.compactTokens(value: state.contextUsedTokens)) of \(SharedRules.shared.compactTokens(value: state.contextWindowTokens)) tokens (\(state.contextPercent)%)"
        )
        .accessibilityLabel("Context used \(state.contextPercent) percent")
    }
}
