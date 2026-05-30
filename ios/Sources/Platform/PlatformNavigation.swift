// Cross-platform navigation chrome shims so Views compile on both
// iOS (where these APIs are native) and macOS (where they're absent
// or renamed).

import SwiftUI

extension View {
    /// `.navigationBarTitleDisplayMode(.inline)` only exists on iOS.
    /// On macOS this is a no-op — macOS window titles are inline by
    /// default.
    @ViewBuilder
    func platformInlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    /// `.topBarLeading` / `.topBarTrailing` are iOS-only. On macOS, the
    /// closest match is `.automatic` (leading) and `.primaryAction`
    /// (trailing).
    static var platformLeading: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarLeading
        #else
        return .automatic
        #endif
    }

    static var platformTrailing: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarTrailing
        #else
        return .primaryAction
        #endif
    }
}
