import DieterClientAPI
import DieterCore
import SwiftUI

/// An account's usage windows ("5 hour", "Weekly", …): a meter of what is
/// left, the share as the core words it, and when the window resets.
struct ProviderUsageMeters: View {
    let provider: String
    let windows: [ClientProviderWindowRow]
    /// Each window's E2E target is "<prefix>.window.<id>".
    var identifierPrefix = "providers.usage"

    var body: some View {
        let now = Date.now.epochMillis
        VStack(alignment: .leading, spacing: 6) {
            ForEach(windows, id: \.id) { window in
                HStack(spacing: 8) {
                    Text(window.name)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(width: 92, alignment: .leading)
                    if window.remaining >= 0 {
                        let tint = ProviderPresentation.tint(provider, window.severity)
                        ProviderMeter(fraction: Double(window.remaining) / 100, tint: tint)
                            .frame(height: 5)
                        Text(SharedRules.shared.providerUsageText(remaining: window.remaining))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(tint)
                            .frame(width: 62, alignment: .trailing)
                    } else {
                        Text("Not reported").font(.caption).foregroundStyle(DieterTheme.tertiary)
                        Spacer()
                    }
                    if !window.resetsAt.isEmpty {
                        Text(
                            SharedRules.shared.providerResetText(resetsAt: window.resetsAt, nowMillis: now, fine: true)
                        )
                        .font(.caption2)
                        .foregroundStyle(DieterTheme.tertiary)
                        .lineLimit(1)
                        .frame(minWidth: 96, alignment: .trailing)
                    }
                }
                .accessibilityElement(children: .combine)
                .e2eTarget(
                    "\(identifierPrefix).window.\(window.id)",
                    text: "\(window.name) · \(SharedRules.shared.providerUsageText(remaining: window.remaining))")
            }
        }
    }
}

/// A thin capsule meter for the remaining share of a usage window.
struct ProviderMeter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(DieterTheme.hairline)
                Capsule().fill(tint).frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .accessibilityHidden(true)
    }
}

/// SF Symbols and colours for provider rows; the wording and severity come
/// from the shared core.
@MainActor
enum ProviderPresentation {
    static func symbol(_ provider: String) -> String {
        switch provider {
        case "chatgpt": "sparkles"
        case "claude": "brain.head.profile"
        default: "key.horizontal"
        }
    }

    /// A low or critical severity wins over the provider's brand colour.
    static func tint(_ provider: String, _ severity: ClientProviderSeverity) -> Color {
        switch severity {
        case .critical: return DieterTheme.coral
        case .low: return DieterTheme.amber
        default:
            switch provider {
            case "chatgpt": return DieterTheme.openAITint
            case "claude": return DieterTheme.amber
            default: return DieterTheme.eyes
            }
        }
    }

    /// The colour of a machine's sign-in state.
    static func stateTint(_ state: String) -> Color {
        switch state {
        case "signed_in": DieterTheme.running
        case "expired": DieterTheme.amber
        case "failed": DieterTheme.coral
        default: DieterTheme.tertiary
        }
    }
}
