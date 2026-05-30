# Design Prompts — iMessage Archiver

Prompts ready to paste into Claude (Sonnet 4.6+ with image input, or any
multimodal LLM) and image-generation tools. Each block stands alone;
copy what you need.

> Open the iOS app on a device or simulator, take a screenshot of each
> screen, and attach it to the relevant prompt. The reviewer's specific
> critique is much sharper when grounded in the actual current state.

---

## 0. Reusable system / context prompt

Paste this at the top of any design conversation. It frames the project
once so subsequent prompts can be terse.

```
You are designing the UI of "iMessage Archiver", an iOS + macOS app that
lets users browse a frozen, read-only archive of their iMessage history.

WHAT THE APP DOES
- Read-only reader for a self-contained archive bundle (~23 GB for a
  100K-message account) that the user generated on their Mac.
- The bundle contains every chat, every message, every attachment
  (photos, videos, audio, PDFs), plus a SQLite database with an FTS5
  full-text index across all messages.
- Used annually-ish: "I want to find that message Mom sent me in 2019."
- Not a Messages client. There is no compose, no send, no react. Only
  browse, search, read, view attachments.

PLATFORMS
- iOS 17+ (iPhone first, iPad later)
- macOS 14+ (Apple Silicon native app)
- Single SwiftUI codebase via a shared Sources/ tree with #if guards.

DESIGN PHILOSOPHY
- Match Apple HIG. Look like an Apple-made app, not a third-party one.
- Visual reference: Messages.app, Mail.app (sidebar list), Photos.app
  for the attachment grid.
- Restraint over decoration. Native SwiftUI primitives; no custom
  bubble shapes, no skeuomorphism.
- Dynamic Type, Dark Mode, VoiceOver. Accessibility is non-optional.
- Read-only nature should be visible but not loud: no faded states,
  but no compose chrome either.

EXISTING CONSTRAINTS
- Data already in place: SwiftUI Views in ios/Sources/Views/.
- Cross-platform shims exist in ios/Sources/Platform/ for things like
  Color.platformSecondaryBackground and ToolbarItemPlacement.platformLeading.
- Stack: SwiftUI, GRDB.swift for SQLite, QuickLook for previews.

OUTPUT STYLE
- Short, decisive critiques over discursive analysis.
- Specific SwiftUI snippets when proposing changes ("use
  `NavigationSplitView` not `NavigationStack`").
- Identify three biggest wins per screen, not twenty small ones.
- When proposing visual changes, sketch with structured ASCII or
  describe in terms of system materials, system colors, SF Symbols.
```

---

## 1. Chat list — review + redesign

```
[paste system prompt above first if starting fresh]

Attached: screenshot of the chat list on macOS Tahoe.

Current implementation, briefly:
- NavigationStack pushes ThreadView on row tap.
- Each row: chat title (sometimes empty if displayName is null AND
  participants list isn't populated), "N messages" count, group icon,
  relative-time on the right ("1 hr, 28 min").
- Searchable bar in toolbar + a second redundant search field.

Critique it. Then propose a redesign that addresses:

a) Mac-native sidebar+detail layout via NavigationSplitView. iOS keeps
   NavigationStack. Show me the top-level View structure for both.

b) Chat row at 60pt height with: monogram avatar (deterministic colour
   from chat_guid hash), title (with fallback chain), one-line last-
   message preview ("You: Sounds good 👍"), smart timestamp
   ("Today 3:42 PM" / "Yesterday" / "Mon" / "5/30/26").

c) Eliminate the dual search affordance. Keep the .searchable modifier
   only; remove the toolbar magnifying-glass.

d) Empty state when no chats match the filter.

Show me a SwiftUI snippet for the row at the row level, plus the
ChatListView structure decision (NavigationSplitView vs Stack with
#if guards).
```

---

## 2. Thread view — review + redesign

```
Attached: screenshot of ThreadView showing a single conversation.

Existing implementation:
- LazyVStack of MessageBubbleView, 200-msg pagination.
- Bubbles: blue right-aligned for "from me", grey left-aligned for
  received. Reactions inline below.
- Tap to reveal timestamp.
- Date separator between days.
- Pagination via "Load earlier messages" button at top.

Critique. Then prescribe:

a) Visual fidelity gap vs Messages.app. Bubble corner radii, tail
   rendering, sender-name placement in group chats.

b) iOS vs Mac differences. On Mac, hover-to-reveal timestamp instead
   of tap. On Mac, support cmd-click to copy a message text. On Mac,
   keyboard shortcuts: up/down arrows to navigate messages?

c) Long-press / context menu actions: Copy text, Show in Finder
   (Mac), Share via NSSharingService (Mac) / ShareLink (iOS).

d) Attachment grid alignment. Currently it sits inside the bubble.
   Apple's Messages.app shows attachments separately, no bubble
   background. Which is correct here?

e) Performance. 200 messages render OK; 5000 messages in a single
   thread might not. Recommend LazyVStack tuning or pagination.

Output: one SwiftUI sketch for the redesigned MessageBubbleView at
the level of cornerRadius, padding, and contextMenu actions.
```

---

## 3. Search — review + redesign

```
Attached: screenshot of SearchView.

Existing implementation:
- Single full-screen List of SearchResultRow items.
- Each row: snippet with FTS5-matched terms highlighted (bold + accent
  colour), sender name, date.
- 200ms debounce.

Critique. Specifically:

a) Result row density. Currently spacious; could be tighter.

b) Context. Show the conversation name above each result so the user
   knows which chat the message is from. Currently only sender is shown.

c) Grouping. Should results group by conversation (collapsible
   sections) or stay flat-by-rank? Apple HIG opinion?

d) Empty / no-results / mid-typing states. Currently uses
   ContentUnavailableView; is the messaging right?

e) Tap behaviour. Currently tap navigates to the thread (in theory —
   actually not wired up yet). Should the tap also scroll to the
   matched message, highlight it for 2s, then fade?

f) iPad layout: search results in left column + thread in right column?

Output: SwiftUI snippet for SearchResultRow with conversation name +
sender + snippet + date in a Mac-native layout.
```

---

## 4. Attachments — review + redesign

```
Attached: screenshot of a message thread with attachments.

Existing implementation:
- AttachmentGridView: LazyVGrid with 80pt thumbnails.
- Tap → QuickLook preview.
- Images: thumbnail loaded from cache.
- Other types: SF Symbol icon + filename.

Critique:

a) Thumbnail rendering quality. Currently scaledToFill clipped to 80pt
   — coarse. Apple Photos shows real aspect ratios in a flexible grid.

b) Loading state. Currently "isLoading = true; do work; isLoading =
   false". No skeleton, no progressive fade-in.

c) Missing-attachment state. We have ~300 attachments where the cloud
   eviction got them. Show "Not downloaded" with iCloud icon — but
   maybe a button to retry / explain?

d) QuickLook integration. .quickLookPreview($previewURL) modifier;
   works on both platforms in iOS 16+ / macOS 13+. Any issues with
   pinning/eviction we should warn about?

e) Video thumbnail. Currently shows a play-icon overlay. Should we
   actually extract a real video frame for the thumbnail? AVAsset is
   available on both platforms.

Output: AttachmentThumbnailView SwiftUI revision with proper aspect-
ratio respecting layout and a skeleton loading state.
```

---

## 5. Empty / error / loading states

```
Existing states in the app:
- "Checking iCloud…" (initial)
- "iCloud Not Available" (no container)
- "No Archive Found" (container empty)
- "Downloading Archive…" with percentage
- "Opening archive…" (reader instantiation)
- "Error: <message>" (red triangle + free-form text)

Critique each. Then prescribe:

a) When does each state appear; are any combinations missing? E.g.
   "downloading but stalled at 12%" — what does the user see?

b) For "No Archive Found": currently a generic message + "Check Again"
   button. Mac users may not know they need to run the Mac archiver
   first. Add specific guidance + a "How to create an archive" link.

c) For errors: the free-form text is dev-friendly but user-hostile.
   "SQLite error 14" means nothing to a normal user. Propose a tiered
   approach: user-friendly summary + collapsible technical detail.

d) For "Opening archive…": currently no progress. For a 100MB
   archive.sqlite this is instant; for a 1GB version (future) it'll
   feel hung. Add a spinner with timing-out language at 5s.

Output: a small Swift enum that classifies recoverable vs unrecoverable
errors plus a unified ErrorView that takes that enum.
```

---

## 6. Design system / tokens

```
Help me write the design system for this app. Output as
Sources/DesignSystem/Tokens.swift (or similar).

REQUIRED TOKENS

Colours (use SwiftUI Color initialisers, semantic naming):
- Accent: defaults to Color.accentColor (we set this in asset catalog)
- Bubble.sent: Color.blue (Messages convention)
- Bubble.received: Color.platformSecondaryBackground
- Reaction.background: Color.platformTertiaryBackground
- Avatar.tints: 12 distinct colours generated from a deterministic
  hash of chat_guid. Should look like Apple's Contacts.app monograms.

Typography:
- .messageTextStyle: .body, designed for readability at Dynamic Type
- .messageTimestampStyle: .caption, .secondary
- .chatTitleStyle: .body.weight(.semibold)
- .chatPreviewStyle: .subheadline, foregroundStyle(.secondary)
- .snippetStyle: AttributedString-aware, with .accentColor for
  matches

Spacing (use multiples of 4pt):
- bubblePaddingHorizontal: 12
- bubblePaddingVertical: 8
- bubbleCornerRadius: 18 (Messages.app uses 18)
- avatarSize: 40
- rowHeight: 60

Animations:
- search debounce timing
- chat selection transition
- attachment load fade-in (120ms)

Output: a single Swift file with extension Color { static let bubbleSent
= ... } and extension Font { static let messageText = ... } patterns
that the existing Views can drop into.
```

---

## 7. App icon — three variation prompts

These go into an image-generation tool (Claude with image generation,
DALL-E 3, Midjourney, etc.). Generate at 1024×1024, then scale down.

### Variation A: Layered Conversations
```
Generate an iOS / macOS app icon for "iMessage Archive" — an app that
preserves a frozen, browsable copy of someone's message history.

Style:
- Square 1024×1024 canvas. macOS applies the corner radius automatically.
- Apple HIG-compliant: single focal element, no text or letters, looks
  great at 32×32.
- Liquid Glass aesthetic: subtle translucency, light highlight at top
  edge, soft inner shadow at bottom.

Composition:
- Background: smooth diagonal gradient from Apple System Blue (#007AFF)
  top-left to Apple System Indigo (#5856D6) bottom-right.
- Foreground: three speech bubbles stacked at slight angles, like a
  fanned deck of cards. The front bubble is white and crisp; the
  middle bubble is 70% opacity; the back bubble is 35% opacity,
  fading into the gradient. Suggests history / depth / archival.
- No text inside the bubbles. Tails optional — if shown, all pointing
  down-left.
- No clock, no calendar, no folder, no vault, no envelope.

Output: PNG 1024×1024 with full bleed. Three variations differing
only in bubble angles and offset.
```

### Variation B: Bubble in a Vault Silhouette
```
Generate an iOS / macOS app icon for "iMessage Archive".

Style: Apple HIG, liquid glass, single focal element, no text.

Composition:
- Background: deep gradient from Apple System Indigo (#5856D6) at top
  to a darker midnight-purple (#2C2A5A) at bottom.
- Foreground: a single white speech bubble at the centre, but contained
  inside a subtle hexagonal frame that suggests a vault or strongbox
  door — six clean edges, slightly thicker at the corners, glass-like
  inner highlight along the top edges.
- The bubble itself is plain white, no inner content.

Output: PNG 1024×1024. Three variations differing in the strength of
the hexagonal frame (subtle, medium, prominent).
```

### Variation C: Timeline Bubble
```
Generate an iOS / macOS app icon for "iMessage Archive".

Style: Apple HIG, liquid glass, single focal element, no text.

Composition:
- Background: warm gradient from Apple System Teal (#5AC8FA) top
  to Apple System Blue (#007AFF) bottom.
- Foreground: a single white speech bubble at the upper centre, with
  a single thin vertical line descending from the bubble's bottom-left
  corner — like a vertical timeline. Three small white dots are
  spaced along the line, suggesting marked points in time / archived
  moments.
- Bubble is plain white, no inner content.

Output: PNG 1024×1024. Three variations differing in the dot count
(2, 3, 4) and line thickness.
```

---

## 8. Wiring the icons in

Once you've picked the winning icon set, drop them in by running:

```bash
python scripts/generate_app_icons.py --master /path/to/winning_master.png
```

(This script — at `scripts/generate_app_icons.py` — needs an extension
to accept `--master`. Currently it always renders the bundled gradient
+ bubble. Worth adding before icon iteration.)

Or manually:

1. Save the chosen 1024×1024 PNG to `assets/AppIcons/master.png`
2. Re-run `python scripts/generate_app_icons.py` to regenerate the
   `.appiconset` directories
3. Open `ios/iMessageArchiver.xcodeproj` and drag the iOS `.appiconset`
   into the iOS target's Assets.xcassets (rename to `AppIcon`)
4. Repeat for the Mac target

---

## 9. Review-only prompt (for an existing screenshot)

If you don't want a redesign, just a critique:

```
Attached: screenshot of a single screen of an iOS / macOS app called
"iMessage Archive" — a read-only reader for archived message bundles.

Give me:
- Three biggest design issues, ordered by severity.
- For each: the specific Apple HIG principle violated.
- For each: a one-sentence fix.
- Skip "could be more colourful" / "needs more whitespace" filler.
- Skip anything that needs a real code change beyond SwiftUI modifiers.

Format: numbered list, ~3 sentences per item.
```

---

## Order of operations recommended

If working through these end-to-end, the right sequence is:

1. **Design system** (Prompt 6) — establishes tokens used by every
   later screen
2. **Chat list** (Prompt 1) — the entry point; biggest UX wins
3. **Thread view** (Prompt 2) — second most-used screen
4. **Search** (Prompt 3)
5. **Empty states** (Prompt 5) — polish that disproportionately
   improves first-launch experience
6. **Attachments** (Prompt 4) — visual quality refinement
7. **App icon** (Prompt 7) — last because it's least informed by
   the final UI direction
