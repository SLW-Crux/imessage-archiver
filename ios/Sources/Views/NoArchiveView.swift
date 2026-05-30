import SwiftUI

struct NoArchiveView: View {
    enum Reason {
        case noContainer, noBundle
    }
    let reason: Reason

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: symbol)
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(instructions)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            if reason == .noBundle {
                Button("Check Again") {
                    appState.coordinator.start()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch reason {
        // "No Archive Yet" — Mac users (and first-run iOS users) don't
        // know an archive must be created by the companion archiver
        // first. "Yet" signals that nothing was lost, just not yet
        // created.
        case .noBundle:    return "No Archive Yet"
        case .noContainer: return "iCloud Drive Required"
        }
    }

    private var symbol: String {
        switch reason {
        case .noBundle:    return "tray.and.arrow.down"
        case .noContainer: return "icloud.slash"
        }
    }

    private var instructions: String {
        switch reason {
        case .noBundle:
            return "Create an archive by running iMessage Archiver on your Mac, then wait for iCloud to sync the bundle to this device."
        case .noContainer:
            return "Turn on iCloud Drive in Settings to sync your archive between devices."
        }
    }
}
