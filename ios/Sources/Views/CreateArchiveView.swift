import SwiftUI

/// SwiftUI screen that drives the native Swift archiver from the Mac
/// app's first-run state. Mac-only — iOS just reads what the Mac
/// produced.
#if os(macOS)
struct CreateArchiveView: View {

    @State private var coordinator = CreateArchiveCoordinator()

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: symbolForPhase)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse, options: phaseIsAnimated ? .repeating : .nonRepeating)
                .accessibilityHidden(true)

            Text(titleForPhase)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(subtitleForPhase)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .padding(.horizontal)

            content
                .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: coordinatorPhaseIsTerminal) { _, terminal in
            // On success, kick the iCloud coordinator to re-scan so the
            // existing reader UI takes over.
            if terminal, case .succeeded = coordinator.phase {
                appState.coordinator.start()
            }
        }
    }

    // MARK: - Phase-specific UI

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .idle:
            Button {
                coordinator.start()
            } label: {
                Label("Create Archive", systemImage: "arrow.down.to.line")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(coordinator.destinationBundleURL == nil)

        case .snapshotting:
            ProgressView("Reading Messages…")
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)

        case .archiving(let p):
            VStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text(p.chatTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(p.messagesWritten) messages · \(p.attachmentsWritten) attachments")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

        case .verifying(let checked, let total):
            VStack(spacing: 8) {
                ProgressView(value: total == 0 ? 0 : Double(checked) / Double(total))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
                Text("Verifying \(checked) of \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

        case .succeeded(let stats):
            VStack(spacing: 8) {
                Label("\(stats.messagesWritten) messages archived", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(stats.attachmentsWritten) attachments · \(stats.attachmentsMissing) missing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .failed(let error):
            VStack(spacing: 12) {
                Text(error.localizedDescription)
                    .font(.body)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                Button("Try Again") {
                    coordinator.start()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Phase metadata

    private var coordinatorPhaseIsTerminal: Bool {
        switch coordinator.phase {
        case .succeeded, .failed: return true
        default: return false
        }
    }

    private var phaseIsAnimated: Bool {
        switch coordinator.phase {
        case .snapshotting, .archiving, .verifying: return true
        default: return false
        }
    }

    private var symbolForPhase: String {
        switch coordinator.phase {
        case .idle:          return "archivebox.fill"
        case .snapshotting:  return "doc.text.magnifyingglass"
        case .archiving:     return "arrow.down.doc"
        case .verifying:     return "checkmark.shield"
        case .succeeded:     return "checkmark.circle.fill"
        case .failed:        return "exclamationmark.triangle"
        }
    }

    private var titleForPhase: String {
        switch coordinator.phase {
        case .idle:          return "Create Your Archive"
        case .snapshotting:  return "Reading Messages"
        case .archiving:     return "Archiving"
        case .verifying:     return "Verifying"
        case .succeeded:     return "Archive Ready"
        case .failed:        return "Couldn't Finish"
        }
    }

    private var subtitleForPhase: String {
        switch coordinator.phase {
        case .idle:
            if coordinator.destinationBundleURL == nil {
                return "iCloud Drive isn't available. Sign in to iCloud and enable iCloud Drive in System Settings, then come back."
            }
            return "Honk reads your Messages database, packages every conversation and attachment into a single bundle, and saves it to iCloud Drive — so you can browse it on your iPhone."
        case .snapshotting:
            return "Taking a clean snapshot of chat.db. Your original Messages history is never modified."
        case .archiving:
            return "This takes a few minutes for the first run. You can leave the app open and come back later."
        case .verifying:
            return "Re-reading every attachment from the archive and confirming its SHA-256 hash matches what we stored."
        case .succeeded:
            return "Your archive is in iCloud Drive. The reader will open it momentarily."
        case .failed:
            return "Try again. If the same error keeps happening, check Full Disk Access for Honk in System Settings → Privacy & Security."
        }
    }
}
#endif
