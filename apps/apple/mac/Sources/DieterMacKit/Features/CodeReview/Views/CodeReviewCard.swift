import DieterClientAPI
import SwiftUI

/// A code review in the transcript, as the core lays it out: what was
/// reviewed and by whom, the reviewer's summary, its findings (each opens to
/// its explanation and suggested fix, and its location opens the file in the
/// conversation's Changes), and the earlier findings this round resolved.
struct CodeReviewCard: View, Equatable {
    @Environment(ConversationContext.self) private var context: ConversationContext?
    let review: ClientTimelineCodeReview
    @State private var resolvedExpanded = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.review == rhs.review }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            details.padding(.top, 8)
            if !review.findings.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(review.findings, id: \.id) { finding in
                        Divider().overlay(DieterTheme.border)
                        CodeReviewFindingRow(reviewID: review.reviewID, finding: finding, openLocation: openLocation)
                    }
                }
                .padding(.top, 8)
            }
            if !review.resolved.isEmpty { resolved.padding(.top, review.findings.isEmpty ? 8 : 0) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: 680, alignment: .leading)
        .background(DieterTheme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DieterTheme.insetRim)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(review.title)
        .accessibilityIdentifier("code-review-\(review.reviewID)")
        .e2eTarget("code-review-\(review.reviewID)", text: review.title)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if review.running {
                    ProgressView().controlSize(.mini)
                } else if !review.error.isEmpty {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(DieterTheme.failed)
                } else {
                    Image(systemName: "eye").foregroundStyle(DieterTheme.tertiary)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(review.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(DieterTheme.text)
                    .lineLimit(1)
                if !review.subtitle.isEmpty {
                    Text(review.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(DieterTheme.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            let counts = [review.countsLabel, review.changeLabel].filter { !$0.isEmpty }
            let origin = [review.roundLabel, review.triggerLabel].filter { !$0.isEmpty }
            if !counts.isEmpty || !origin.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !counts.isEmpty {
                        Text(counts.joined(separator: " · "))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DieterTheme.text)
                    }
                    if !origin.isEmpty {
                        Text(origin.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(DieterTheme.tertiary)
                    }
                }
            }
            if !review.summary.isEmpty {
                ConversationMarkdownView(source: review.summary, inUserBubble: false)
            }
            if !review.security.isEmpty {
                Label {
                    Text("Security: \(review.security)").fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(DieterTheme.attention)
                .accessibilityIdentifier("code-review-security-\(review.reviewID)")
            }
            if !review.error.isEmpty {
                Text(review.error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DieterTheme.failed)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private var resolved: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(DieterTheme.border)
            Button {
                resolvedExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").foregroundStyle(DieterTheme.running)
                    Text("Resolved (\(review.resolved.count))")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(DieterTheme.subtle)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DieterTheme.tertiary)
                        .rotationEffect(.degrees(resolvedExpanded ? 90 : 0))
                }
                .font(.system(size: 11))
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(resolvedExpanded ? "Hide" : "Show") resolved findings")
            .accessibilityIdentifier("code-review-resolved-\(review.reviewID)")
            .e2eTarget("code-review-resolved-\(review.reviewID)")
            if resolvedExpanded {
                ForEach(review.resolved, id: \.id) { finding in
                    Divider().overlay(DieterTheme.border)
                    CodeReviewFindingRow(reviewID: review.reviewID, finding: finding, openLocation: nil)
                }
            }
        }
    }

    /// Opens a finding's file in the conversation's Changes; nil outside a conversation.
    private var openLocation: ((ClientTimelineCodeReviewFinding) -> Void)? {
        guard let context else { return nil }
        return { finding in context.openChange(path: finding.file) }
    }
}

/// One finding: its severity, title and location; opening it shows its
/// explanation and suggested fix.
struct CodeReviewFindingRow: View {
    let reviewID: String
    let finding: ClientTimelineCodeReviewFinding
    let openLocation: ((ClientTimelineCodeReviewFinding) -> Void)?
    @State private var expanded = false

    private var expandable: Bool { !finding.body.isEmpty || !finding.suggestion.isEmpty }
    private var identifier: String { "code-review-finding-\(reviewID)-\(finding.id)" }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CodeReviewSeverityChip(severity: finding.severity, label: finding.severityLabel)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    if expandable { expanded.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(finding.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DieterTheme.text)
                            .lineLimit(expanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        if !finding.statusLabel.isEmpty, finding.status != "new" {
                            Text(finding.statusLabel)
                                .font(.system(size: 10.5))
                                .foregroundStyle(DieterTheme.tertiary)
                                .lineLimit(1)
                        }
                        if expandable {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(DieterTheme.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(finding.severityLabel): \(finding.title)")
                .accessibilityHint(expandable ? (expanded ? "Hides the explanation" : "Shows the explanation") : "")
                if !finding.locationLabel.isEmpty { location }
                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        if !finding.body.isEmpty {
                            ConversationMarkdownView(source: finding.body, inUserBubble: false)
                        }
                        if !finding.suggestion.isEmpty {
                            Text("Suggested fix")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DieterTheme.subtle)
                            ConversationMarkdownView(source: finding.suggestion, inUserBubble: false)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .e2eTarget(identifier, text: finding.title)
    }

    @ViewBuilder private var location: some View {
        if let openLocation, !finding.file.isEmpty {
            Button {
                openLocation(finding)
            } label: {
                Text(finding.locationLabel)
                    .font(DieterFont.monoSmall)
                    .foregroundStyle(DieterTheme.action)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Show in Changes")
            .accessibilityLabel("Show \(finding.locationLabel) in Changes")
            .accessibilityIdentifier("code-review-location-\(reviewID)-\(finding.id)")
            .e2eTarget("code-review-location-\(reviewID)-\(finding.id)")
        } else {
            Text(finding.locationLabel)
                .font(DieterFont.monoSmall)
                .foregroundStyle(DieterTheme.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// "High", "Medium" or "Low" in its severity's color.
struct CodeReviewSeverityChip: View {
    let severity: String
    let label: String

    private var tint: Color {
        switch severity {
        case "high": DieterTheme.failed
        case "medium": DieterTheme.attention
        default: DieterTheme.subtle
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}
