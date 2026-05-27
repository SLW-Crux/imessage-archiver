import SwiftUI

struct NoArchiveView: View {
    enum Reason {
        case noContainer, noBundle
    }
    let reason: Reason

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "archivebox")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(reason == .noContainer ? "iCloud Not Available" : "No Archive Found")
                .font(.title2.bold())
            Text(instructions)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if reason == .noBundle {
                Button("Check Again") {
                    appState.coordinator.start()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }

    private var instructions: String {
        switch reason {
        case .noContainer:
            return "Enable iCloud Drive in Settings → [Your Name] → iCloud → iCloud Drive to sync your archive."
        case .noBundle:
            return "Run iMessage Archiver on your Mac to create an archive, then wait for iCloud to sync."
        }
    }
}
