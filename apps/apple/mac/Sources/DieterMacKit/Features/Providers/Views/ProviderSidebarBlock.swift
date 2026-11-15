import DieterClientAPI
import SwiftUI

/// The providers part of the sidebar's status panel: one meter per provider
/// for the tightest window of the accounts included in summaries. It keeps
/// its place while the slice loads or no account exists, so the sidebar never
/// jumps, and opens Settings › Providers.
struct ProviderSidebarBlock: View {
    @Environment(DieterStore.self) private var store

    private var providers: ProvidersModel { store.providersModel }

    var body: some View {
        let items = providers.summary.items
        VStack(alignment: .leading, spacing: 4) {
            Text("Providers")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DieterTheme.tertiary)
                .padding(.horizontal, 8).frame(height: 22)
                .e2eTarget("sidebar.providers-title")
            Button {
                store.openSettings(section: .providers)
            } label: {
                Group {
                    if items.isEmpty {
                        Text(emptyText)
                            .font(.system(size: 11))
                            .foregroundStyle(DieterTheme.tertiary)
                            .lineLimit(2)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(items, id: \.provider) { item in
                                ProviderSummaryRow(item: item)
                                    .e2eTarget("sidebar.provider.\(item.provider)", text: item.text)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8).padding(.bottom, 2)
            .help("Open Settings › Providers")
            .accessibilityLabel(accessibilityLabel(items))
            .accessibilityIdentifier("sidebar.providers.open")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.providers")
        .onAppear { providers.observe() }
        .onDisappear { providers.release() }
    }

    private var emptyText: String {
        if let problem = providers.problem { return problem }
        return providers.hasAccounts ? "Usage not reported yet" : "Add a Claude or ChatGPT account"
    }

    private func accessibilityLabel(_ items: [ClientProviderSummaryItem]) -> String {
        items.isEmpty ? "Providers: \(emptyText)" : items.map(\.text).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

private struct ProviderSummaryRow: View {
    let item: ClientProviderSummaryItem

    var body: some View {
        let tint = ProviderPresentation.tint(item.provider, item.severity)
        HStack(spacing: 6) {
            Image(systemName: ProviderPresentation.symbol(item.provider))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(item.providerName)
                .font(.system(size: 11.5))
                .foregroundStyle(DieterTheme.text.opacity(0.88))
                .lineLimit(1)
                .frame(minWidth: 42, maxWidth: .infinity, alignment: .leading)
            if item.remaining >= 0 {
                ProviderMeter(fraction: Double(item.remaining) / 100, tint: tint)
                    .frame(width: 44, height: 4)
                Text("\(item.remaining)%")
                    .font(DieterFont.monoSmall)
                    .foregroundStyle(DieterTheme.subtle)
                    .monospacedDigit()
                    .frame(minWidth: 30, alignment: .trailing)
            } else {
                Text("—").font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
        }
        .help(item.text)
    }
}
