import SwiftUI
import QuickLook

struct AttachmentGridView: View {
    let attachments: [Attachment]
    let cache: AttachmentCache
    let tarReader: TarReader?

    @State private var previewURL: URL?
    @State private var previewGuid: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 4) {
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

    @State private var thumbnail: PlatformImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.platformSecondaryBackground)
                .frame(width: 80, height: 80)

            if let thumb = thumbnail {
                Image(platformImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 80)
                    .clipped()
                    .cornerRadius(8)
            } else if attachment.isExtractable {
                if isLoading {
                    ProgressView().frame(width: 80, height: 80)
                } else {
                    icon
                }
            } else {
                missingIcon
            }
        }
        .task(id: attachment.attachmentGuid) {
            await loadThumbnail()
        }
        .accessibilityLabel(attachment.filename ?? "Attachment")
    }

    @ViewBuilder
    private var icon: some View {
        let mime = attachment.mimeType ?? ""
        VStack(spacing: 4) {
            Image(systemName: mimeIcon(mime))
                .font(.title2)
                .foregroundStyle(.secondary)
            if let name = attachment.filename {
                Text(name)
                    .font(.system(size: 9))
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 80, height: 80)
    }

    @ViewBuilder
    private var missingIcon: some View {
        VStack(spacing: 4) {
            Image(systemName: "icloud.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Not downloaded")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 80, height: 80)
    }

    private func loadThumbnail() async {
        guard attachment.isExtractable, let tarReader, !isLoading else { return }
        let mime = attachment.mimeType ?? ""
        guard mime.hasPrefix("image/") else { return }
        isLoading = true
        if let url = try? await cache.url(for: attachment, tarReader: tarReader),
           let data = try? Data(contentsOf: url),
           let img = PlatformImage(data: data) {
            thumbnail = img
        }
        isLoading = false
    }

    private func mimeIcon(_ mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "play.circle.fill" }
        if mime.hasPrefix("audio/") { return "waveform" }
        return "doc"
    }
}
