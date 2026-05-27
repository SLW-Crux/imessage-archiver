import SwiftUI

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
                NoArchiveView(reason: .noBundle)
            case .downloading(let progress):
                downloadingView(progress: progress)
            case .ready(let bundleURL):
                mainView(bundleURL: bundleURL)
            case .error(let msg):
                errorView(message: msg)
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
        } else {
            ProgressView("Opening archive…")
                .task { appState.onBundleReady(bundleURL) }
        }
    }

    @ViewBuilder
    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Error")
                .font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
