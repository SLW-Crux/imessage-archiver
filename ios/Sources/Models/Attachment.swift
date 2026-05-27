import Foundation

struct Attachment: Identifiable, Hashable, Sendable {
    let attachmentGuid: String
    let messageGuid: String
    let filename: String?
    let mimeType: String?
    let uti: String?
    let size: Int64
    let sha256: String?
    let tarOffset: Int64?
    let tarLength: Int64?
    let state: AttachmentState

    var id: String { attachmentGuid }

    var isExtractable: Bool {
        state == .localPresent && tarOffset != nil && tarLength != nil
    }
}

enum AttachmentState: String, Sendable {
    case localPresent = "LOCAL_PRESENT"
    case missing = "MISSING"
    case zeroByte = "ZERO_BYTE"
    case unreadable = "UNREADABLE"
}
