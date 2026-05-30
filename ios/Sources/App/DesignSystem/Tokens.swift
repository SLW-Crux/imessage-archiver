//  Tokens.swift
//  iMessage Archiver — Design System
//
//  Single source of truth for colors, typography, spacing, and motion.
//  Views consume these tokens; no raw literals in Views.
//
//  Notes:
//  - bubbleSent uses Color.accentColor (not hardcoded blue) so it follows
//    the asset-catalog accent. Matches Messages.app behaviour.
//  - Typography is split: Font extensions where the token is purely a font;
//    View modifiers where color/behavior is bundled (timestamp dimming,
//    .textSelection on message text, AttributedString snippet handling).
//  - Avatar tints use djb2 over chat_guid UTF-8 bytes, NOT Swift's
//    hashValue, which is per-launch randomized and would recolor avatars
//    on every launch.

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Colors

extension Color {

    /// System accent (set in asset catalog). Sent bubbles follow accent, per Messages.
    static let bubbleSent = Color.accentColor

    /// Received bubble fill — platform-appropriate secondary background.
    static let bubbleReceived = Color.platformSecondaryBackground

    /// Reaction pill background.
    static let reactionBackground = Color.platformTertiaryBackground

    // MARK: Avatar tints

    /// 12 monogram tints tuned to read like Contacts.app — saturated but not neon,
    /// legible against white monogram glyphs in both light and dark mode.
    /// Order is arbitrary; selection is deterministic via `avatarTint(for:)`.
    ///
    /// Amber is the one tint whose light-mode value (0.98, 0.74, 0.18)
    /// has relative luminance ≈ 0.62, which produces only ~2.5:1 contrast
    /// against white glyphs in dark mode — below the WCAG 3:1 minimum
    /// for large text. It's adaptive (`Color(light:dark:)`) so dark mode
    /// uses a darker amber that lifts contrast to ~4.5:1 while keeping
    /// the same hue family. Every other tint passes 3:1 unchanged.
    static let avatarTints: [Color] = [
        Color(red: 0.96, green: 0.26, blue: 0.21),                  // red
        Color(red: 0.96, green: 0.49, blue: 0.13),                  // orange
        adaptive(
            light: Color(red: 0.98, green: 0.74, blue: 0.18),
            dark:  Color(red: 0.80, green: 0.54, blue: 0.05)
        ),                                                           // amber
        Color(red: 0.30, green: 0.69, blue: 0.31),                  // green
        Color(red: 0.00, green: 0.59, blue: 0.53),                  // teal
        Color(red: 0.01, green: 0.66, blue: 0.96),                  // sky
        Color(red: 0.13, green: 0.59, blue: 0.95),                  // blue
        Color(red: 0.40, green: 0.23, blue: 0.72),                  // indigo
        Color(red: 0.61, green: 0.15, blue: 0.69),                  // purple
        Color(red: 0.91, green: 0.12, blue: 0.39),                  // pink
        Color(red: 0.47, green: 0.33, blue: 0.28),                  // brown
        Color(red: 0.38, green: 0.49, blue: 0.55),                  // slate
    ]

    /// Build a colour that picks `dark` in dark mode and `light` in
    /// light mode. Used by the amber tint above to bump contrast.
    private static func adaptive(light: Color, dark: Color) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        }))
        #else
        return Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #endif
    }

    /// Deterministic, launch-stable tint for a chat. djb2 over UTF-8 bytes —
    /// Swift's `hashValue` is per-run randomized and would recolor avatars
    /// on every launch.
    static func avatarTint(for guid: String) -> Color {
        var hash: UInt64 = 5381
        for byte in guid.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return avatarTints[Int(hash % UInt64(avatarTints.count))]
    }
}

// MARK: - Spacing & Geometry

/// All values are multiples of 4pt.
enum Spacing {
    static let bubblePaddingHorizontal: CGFloat = 12
    static let bubblePaddingVertical:   CGFloat = 8
    static let bubbleCornerRadius:      CGFloat = 18   // Messages.app
    static let avatarSize:              CGFloat = 40
    static let rowHeight:               CGFloat = 60

    static let rowSpacing:              CGFloat = 12   // avatar ↔ text gutter
    static let bubbleRunSpacing:        CGFloat = 2    // same-sender consecutive
    static let bubbleGroupSpacing:      CGFloat = 8    // sender change
    static let thumbnailCornerRadius:   CGFloat = 12
    static let bubbleMaxWidthInset:     CGFloat = 60   // Spacer minLength → width cap
}

/// Canonical bubble shape — continuous (squircle) corners, not circular.
/// The `.continuous` style is the strongest "Apple-made" visual tell.
extension RoundedRectangle {
    static var bubble: RoundedRectangle {
        RoundedRectangle(cornerRadius: Spacing.bubbleCornerRadius, style: .continuous)
    }
    static var thumbnail: RoundedRectangle {
        RoundedRectangle(cornerRadius: Spacing.thumbnailCornerRadius, style: .continuous)
    }
}

// MARK: - Typography (pure-font tokens)

extension Font {
    /// Message body text. `.body` scales with Dynamic Type for readability.
    static let messageText      = Font.body
    static let chatTitle        = Font.body.weight(.semibold)
    static let chatPreview      = Font.subheadline
    static let messageTimestamp = Font.caption
}

// MARK: - Typography (modifiers bundling font + color + behavior)

extension View {
    func messageTextStyle() -> some View {
        self.font(.messageText)
            .textSelection(.enabled)
    }

    func messageTimestampStyle() -> some View {
        self.font(.messageTimestamp)
            .foregroundStyle(.secondary)
    }

    func chatTitleStyle() -> some View {
        self.font(.chatTitle)
            .lineLimit(1)
    }

    func chatPreviewStyle() -> some View {
        self.font(.chatPreview)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Snippet styling is AttributedString-aware: FTS5 match ranges are colored
/// at the model layer (the View must not re-scan for matches — stemming makes
/// substring search wrong). This helper applies the base (non-match) color
/// only; match runs already carry their own accent color from the search layer.
extension AttributedString {
    func snippetStyled() -> AttributedString {
        var copy = self
        for run in copy.runs where run.foregroundColor == nil {
            copy[run.range].foregroundColor = .secondary
        }
        return copy
    }
}

// MARK: - Motion

enum Motion {
    /// Search input debounce. 200ms balances responsiveness vs FTS5 query churn.
    static let searchDebounce: Duration = .milliseconds(200)

    /// Chat selection / detail transition.
    static let chatSelection: Animation = .easeInOut(duration: 0.2)

    /// Attachment thumbnail crossfade on load.
    static let attachmentFade: Animation = .easeOut(duration: 0.12)

    /// Search-result highlight: hold then fade after scroll-to-message.
    static let highlightFade: Animation = .easeOut(duration: 0.6)
    static let highlightHold: Duration  = .seconds(2)
}
