import SwiftUI

struct ArchiveInfoView: View {
    let manifest: ArchiveManifest

    var body: some View {
        List {
            Section("Archive") {
                row("Schema Version", value: "\(manifest.schemaVersion)")
                row("Archiver Version", value: manifest.archiverVersion)
                row("Created", value: manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                row("Last Updated", value: manifest.lastUpdatedAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section("Contents") {
                row("Conversations", value: manifest.chatCount.formatted())
                row("Messages", value: manifest.messageCount.formatted())
                row("Attachments", value: manifest.attachmentCount.formatted())
                row("Missing Attachments", value: manifest.missingAttachmentCount.formatted())
            }
            Section("Storage") {
                row("Archive Size", value: ByteCountFormatter.string(
                    fromByteCount: manifest.archiveSizeBytes, countStyle: .file))
            }
        }
        .navigationTitle("Archive Info")
        .platformInlineTitle()
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
