import SwiftUI
import QuickLook
import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct AttachmentGridView: View {
    let attachments: [Attachment]
    let cache: AttachmentCache
    let tarReader: TarReader?

    @State private var previewURL: URL?
    @State private var previewGuid: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 4)], spacing: 4) {
            ForEach(attachments) { attachment in
                AttachmentThumbnailView(
                    attachment: attachment,
                    cache: cache,
                    tarReader: tarReader
                )
                .onTapGesture {
                    Task { await tap(attachment) }
                }
            }
        }
        .padding(.horizontal, 8)
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { _, newValue in
            // When the preview dismisses (newValue == nil), unpin so the
            // cache can evict the file if needed.
            if newValue == nil, let guid = previewGuid {
                cache.unpin(guid)
                previewGuid = nil
            }
        }
    }

    private func tap(_ attachment: Attachment) async {
        guard attachment.isExtractable, let tarReader else { return }
        // Pin BEFORE extracting so the cache can't evict the file while
        // QuickLook is still presenting it.
        cache.pin(attachment.attachmentGuid)
        previewGuid = attachment.attachmentGuid
        do {
            previewURL = try await cache.url(for: attachment, tarReader: tarReader)
        } catch {
            cache.unpin(attachment.attachmentGuid)
            previewGuid = nil
        }
    }
}

struct AttachmentThumbnailView: View {
    let attachment: Attachment
    let cache: AttachmentCache
    let tarReader: TarReader?

    @Environment(\.displayScale) private var displayScale
    @State private var phase: Phase = .loading

    /// Phase machine keeps illegal mid-load states unrepresentable. A
    /// thumbnail is exactly one of: loading, decoded image, file we know
    /// nothing about beyond its symbol, or "not included in the bundle."
    enum Phase: Equatable {
        case loading
        case image(PlatformImage)
        case missing
        case file(symbol: String, name: String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            // Compare by case; the inner PlatformImage doesn't conform
            // to Equatable, and re-evaluating an .image vs the same
            // .image is the no-op we want.
            switch (lhs, rhs) {
            case (.loading, .loading), (.missing, .missing): return true
            case (.image, .image): return true
            case (.file(let s1, let n1), .file(let s2, let n2)):
                return s1 == s2 && n1 == n2
            default: return false
            }
        }
    }

    private let side: CGFloat = 80

    var body: some View {
        Group {
            switch phase {
            case .loading:
                placeholder
                    .overlay { ProgressView().controlSize(.small) }
                    .redacted(reason: .placeholder)

            case .image(let img):
                Image(platformImage: img)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)

            case .missing:
                missingView

            case .file(let symbol, let name):
                fileView(symbol: symbol, name: name)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle.thumbnail)
        .overlay(alignment: .bottomTrailing) {
            // Keep the play overlay on top of the real video frame so
            // type is still signaled when we successfully extract one.
            if isVideo, case .image = phase {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, .black.opacity(0.4))
                    .padding(4)
            }
        }
        .task(id: attachment.attachmentGuid) { await load() }
        .animation(Motion.attachmentFade, value: phase)
        .accessibilityLabel(accessibilityLabel)
    }

    private var placeholder: some View {
        RoundedRectangle.thumbnail
            .fill(Color.platformSecondaryBackground)
    }

    /// Honest missing-attachment state. No cloud icon (the bundle is
    /// frozen — nothing to download), no retry button (no live source
    /// to retry against). The user knows the gap is real.
    private var missingView: some View {
        placeholder
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Not Included")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
    }

    private func fileView(symbol: String, name: String) -> some View {
        placeholder
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: symbol).font(.title2)
                    Text(name)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 4)
                }
                .foregroundStyle(.secondary)
            }
    }

    private var displayFilename: String? {
        guard let name = attachment.filename, !name.isEmpty else { return nil }
        let base = (name as NSString).lastPathComponent
        return base.isEmpty ? nil : base
    }

    private var mime: String { attachment.mimeType ?? "" }
    private var isImage: Bool { mime.hasPrefix("image/") }
    private var isVideo: Bool { mime.hasPrefix("video/") }

    private func mimeSymbol() -> String {
        if mime.hasPrefix("audio/") { return "waveform" }
        return "doc"
    }

    private var accessibilityLabel: String {
        switch phase {
        case .missing:
            return "\(displayFilename ?? "Attachment"), not included in archive"
        default:
            return displayFilename ?? "Attachment"
        }
    }

    private func load() async {
        // Not extractable = the bundle does not contain this attachment.
        // This is the honest gap — no retry against a remote source
        // exists for a frozen archive.
        guard attachment.isExtractable, let tarReader else {
            phase = .missing
            return
        }

        let url: URL
        do {
            url = try await cache.url(for: attachment, tarReader: tarReader)
        } catch {
            phase = .missing
            return
        }

        // Decode at the pixel target — `side * 2 * displayScale` covers
        // Retina without loading the full source. ImageIO downsamples
        // directly inside CGImageSourceCreateThumbnailAtIndex.
        let maxPixel = side * 2 * displayScale

        if isImage {
            if let cg = await Thumbnailer.image(at: url, maxPixel: maxPixel),
               let platform = Self.platformImage(from: cg) {
                phase = .image(platform)
            } else {
                phase = .missing
            }
        } else if isVideo {
            if let cg = await Thumbnailer.videoFrame(at: url, maxPixel: maxPixel),
               let platform = Self.platformImage(from: cg) {
                phase = .image(platform)
            } else {
                phase = .file(symbol: "video.circle", name: displayFilename ?? "Video")
            }
        } else {
            phase = .file(symbol: mimeSymbol(), name: displayFilename ?? "File")
        }
    }

    private static func platformImage(from cg: CGImage) -> PlatformImage? {
        #if os(macOS)
        // `size: .zero` gives the NSImage no intrinsic dimensions, which
        // makes SwiftUI's `.scaledToFill()` produce a zero-sized result
        // because the aspect-ratio math has nothing to compute from —
        // the Mac UI renders an empty thumbnail. Pass the CGImage's
        // actual pixel dimensions so layout can scale correctly.
        return NSImage(
            cgImage: cg,
            size: NSSize(width: cg.width, height: cg.height)
        )
        #else
        // UIImage already uses CGImage's pixel dimensions as the
        // intrinsic size by default — no equivalent fix needed on iOS.
        return UIImage(cgImage: cg)
        #endif
    }
}
