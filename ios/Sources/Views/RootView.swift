import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.coordinator.state {
            case .checking:
                ProgressView("Checking iCloud…")
            case .noContainer:
                NoArchiveView(reason: .noContainer)
            case .noBundle:
                // Mac runs the native archiver inline — show the
                // CreateArchiveView so the user can build the archive
                // without ever touching Python or a CLI. iOS stays on
                // the read-only "No Archive Yet" prompt; it doesn't
                // own a Messages database to archive.
                #if os(macOS)
                CreateArchiveView()
                #else
                NoArchiveView(reason: .noBundle)
                #endif
            case .downloading(let progress):
                downloadingView(progress: progress)
            case .ready(let bundleURL):
                mainView(bundleURL: bundleURL)
            case .error(let msg):
                ErrorView(
                    error: errorFromMessage(msg),
                    onAction: handleAction
                )
            }
        }
        .onAppear { appState.coordinator.start() }
    }

    @ViewBuilder
    private func downloadingView(progress: Double) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text("Downloading Archive…")
                .font(.headline)
            ProgressView(value: progress)
                .frame(maxWidth: 260)
            Text("\(Int(progress * 100))%")
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    @ViewBuilder
    private func mainView(bundleURL: URL) -> some View {
        if let reader = appState.reader {
            ChatListView(reader: reader)
        } else if let err = appState.loadError {
            // Surface AppState.onBundleReady throws via the tiered
            // ErrorView — previously the UI sat on "Opening archive…"
            // indefinitely while loadError was set silently. This is
            // the only place a reader-open error becomes user-visible.
            ErrorView(
                error: ArchiveError.classify(err),
                onAction: handleAction
            )
        } else {
            ProgressView("Opening archive…")
                .task { appState.onBundleReady(bundleURL) }
        }
    }

    /// Coordinator errors arrive as String messages today (the iCloud
    /// state machine is unchanged in this PR). Wrap them in an NSError
    /// so the tiered detail still has something to show, and let
    /// ArchiveError.classify do best-effort recognition.
    private func errorFromMessage(_ msg: String) -> ArchiveError {
        let ns = NSError(
            domain: "AppCoordinator",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: msg]
        )
        return ArchiveError.classify(ns)
    }

    private func handleAction(_ kind: ArchiveError.Action.Kind) {
        switch kind {
        case .retry:
            appState.coordinator.start()
        case .openSettings:
            openSystemSettings()
        case .openHelp, .openAppStore, .reportIssue:
            // Resources (help docs, App Store listing, issue link) not
            // wired yet. The case still routes the right CTA copy, so
            // adding the actual URL later is a one-line change.
            break
        }
    }

    private func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #else
        // Generic System Settings root. Deep-linking to specific panes
        // (Apple ID, iCloud Drive) is fragile across macOS versions;
        // leave the user one tap away rather than guess wrong.
        if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
