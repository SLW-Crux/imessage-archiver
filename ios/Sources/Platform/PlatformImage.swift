// Cross-platform Image bridging so the SwiftUI Views compile on both iOS
// and macOS. UIImage on iOS, NSImage on macOS — they're functionally
// identical for our usage (load Data → display in SwiftUI.Image).

import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    /// Construct a SwiftUI Image from a platform-appropriate image instance.
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension Color {
    /// macOS uses `NSColor.windowBackgroundColor` etc., and the iOS
    /// `Color(.secondarySystemBackground)` constant doesn't exist there.
    /// This shim picks a sensible equivalent on each platform.
    static var platformSecondaryBackground: Color {
        #if os(iOS)
        return Color(.secondarySystemBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var platformTertiaryBackground: Color {
        #if os(iOS)
        return Color(.tertiarySystemBackground)
        #else
        return Color(nsColor: .underPageBackgroundColor)
        #endif
    }
}
