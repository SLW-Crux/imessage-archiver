import SwiftUI
import QuickLook

struct AttachmentGridView: View {
    let attachments: [Attachment]
    let cache: AttachmentCache
    let tarReader: TarReader?

    @State private var previewURL: URL?

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
    }

    private func tap(_ attachment: Attachment) async {
        guard attachment.isExtractable, let tarReader else { return }
        previewURL = try? await cache.url(for: attachment, tarReader: tarReader)
    }
}

struct AttachmentThumbnailView: View {
    let attachment: Attachment
    let cache: AttachmentCache
    let tarReader: TarReader?

    @State private var thumbnail: UIImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 80, height: 80)

            if let thumb = thumbnail {
                Image(uiImage: thumb)
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
           let img = UIImage(data: data) {
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
