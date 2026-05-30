import SwiftUI

/// Renders an `ArchiveError` with a user-friendly title + message + CTA
/// and a collapsible "Technical Details" disclosure for support copies.
/// Hides the raw underlying error string from the primary view, but
/// keeps it selectable / copyable inside the disclosure.
struct ErrorView: View {
    let error: ArchiveError
    let onAction: (ArchiveError.Action.Kind) -> Void

    @State private var showDetail = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: error.summary.sfSymbol)
                .font(.system(size: 48))
                .foregroundStyle(error.isRecoverable ? .secondary : .red)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text(error.summary.title)
                .font(.title2).fontWeight(.semibold)
                .multilineTextAlignment(.center)

            Text(error.summary.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if let action = error.primaryAction {
                Button(action.title) { onAction(action.kind) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            // Tiered detail: hidden by default, expandable for bug reports.
            if let detail = error.technicalDetail {
                DisclosureGroup("Technical Details", isExpanded: $showDetail) {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .frame(maxWidth: 360)
                .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
