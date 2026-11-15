import DieterClientAPI
import SwiftUI

/// The conversation's provider account cannot run on its machine, e.g.
/// "Work isn't signed in on box": sign it in there, or choose another account
/// for the next message.
struct ProviderNoticeBanner: View {
    let notice: ClientProviderNotice
    /// The composer's account choices; empty when there is nothing to switch to.
    let accounts: [ClientAgentAccountOption]
    let signIn: () -> Void
    let chooseAccount: (String) -> Void

    private var offersSignIn: Bool { notice.action == "sign_in" || notice.action == "sign_in_again" }
    private var alternatives: [ClientAgentAccountOption] { accounts.filter { $0.id != notice.accountID } }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DieterTheme.amber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(DieterTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .e2eTarget("conversation.provider-notice.title", text: notice.title)
                Text("The next message waits until its account can run on \(notice.machine).")
                    .font(.caption).foregroundStyle(DieterTheme.subtle)
            }
            Spacer(minLength: 8)
            if !alternatives.isEmpty {
                Menu("Choose account") {
                    ForEach(alternatives, id: \.id) { account in
                        Button(AccountOptionText.title(account)) { chooseAccount(account.id) }
                            .disabled(!account.ready)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("conversation.provider-notice.choose")
                .e2eTarget("conversation.provider-notice.choose")
            }
            if offersSignIn {
                Button(notice.action == "sign_in_again" ? "Sign in again" : "Sign in", action: signIn)
                    .buttonStyle(DieterBarButtonStyle(prominent: true, size: 26))
                    .accessibilityIdentifier("conversation.provider-notice.signin")
                    .e2eTarget("conversation.provider-notice.signin")
            }
        }
        .padding(14)
        .background(DieterTheme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DieterTheme.amber.opacity(0.4), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.provider-notice")
    }
}

/// How account pickers word an option: "Work · alice@corp.com · Max", or
/// why it cannot run: "Home · Not signed in on box".
enum AccountOptionText {
    static func title(_ account: ClientAgentAccountOption) -> String {
        let detail = account.ready ? account.detail : account.reason
        return detail.isEmpty ? account.label : "\(account.label) · \(detail)"
    }
}
