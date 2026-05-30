#if os(macOS)
import SwiftUI

@main
struct iMessageArchiverMacApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            // Add some basic Mac-native commands. Future v1.x can expand
            // these (Open Recent, Reveal in Finder, etc.).
            CommandGroup(replacing: .newItem) {}
        }
    }
}
#endif
