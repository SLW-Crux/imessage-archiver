import Foundation

/// Classifies failures by what the *user* can do about them — not by
/// source. The summary text is derived from the case; SQLite / NSError
/// internals only surface in the optional `technicalDetail` string for
/// bug-report copies.
///
/// "SQLite error 14" no longer reaches the user; it lives only in the
/// collapsible DisclosureGroup inside `ErrorView`.
enum ArchiveError: Error, Identifiable {

    // Recoverable: user has a clear, valid action.
    case iCloudSignedOut
    case iCloudDriveDisabled
    case networkUnavailable
    case downloadStalled(bytesReceived: Int64)
    case downloadFailed(partial: Bool)

    // Recoverable only by re-creating on the Mac (action is elsewhere).
    case archiveCorrupt
    case schemaTooNew(found: Int, supported: Int)
    case schemaTooOld(found: Int, supported: Int)

    // Unrecoverable in-app: surface detail, offer a generic retry.
    case readerFailed(underlying: Error)
    case unknown(underlying: Error)

    var id: String { summary.title }

    var isRecoverable: Bool {
        switch self {
        case .iCloudSignedOut, .iCloudDriveDisabled, .networkUnavailable,
             .downloadStalled, .downloadFailed,
             .archiveCorrupt, .schemaTooNew, .schemaTooOld:
            return true
        case .readerFailed, .unknown:
            return false
        }
    }

    struct Summary {
        let title: String
        let message: String
        let sfSymbol: String
    }

    /// User-facing copy. Never exposes SQLite / NSError internals.
    var summary: Summary {
        switch self {
        case .iCloudSignedOut:
            return .init(title: "Not Signed In to iCloud",
                         message: "Sign in to iCloud to access your archive.",
                         sfSymbol: "icloud.slash")
        case .iCloudDriveDisabled:
            return .init(title: "iCloud Drive Is Off",
                         message: "Turn on iCloud Drive in Settings to sync your archive.",
                         sfSymbol: "icloud.slash")
        case .networkUnavailable:
            return .init(title: "No Internet Connection",
                         message: "Connect to the internet to download your archive.",
                         sfSymbol: "wifi.slash")
        case .downloadStalled:
            return .init(title: "Download Paused",
                         message: "Waiting for a stable connection. This will resume automatically.",
                         sfSymbol: "arrow.down.circle.dotted")
        case .downloadFailed(let partial):
            return .init(title: "Download Didn’t Finish",
                         message: partial
                            ? "Part of the archive downloaded. You can resume or start over."
                            : "The download failed. Please try again.",
                         sfSymbol: "exclamationmark.icloud")
        case .archiveCorrupt:
            return .init(title: "Archive Is Damaged",
                         message: "This archive can’t be opened. Re-create it on your Mac to fix it.",
                         sfSymbol: "externaldrive.badge.exclamationmark")
        case .schemaTooNew:
            return .init(title: "Update Needed",
                         message: "This archive was made by a newer version of the app. Update to open it.",
                         sfSymbol: "arrow.up.circle")
        case .schemaTooOld:
            return .init(title: "Archive Is Outdated",
                         message: "Re-create this archive on your Mac to open it in this version.",
                         sfSymbol: "clock.arrow.circlepath")
        case .readerFailed, .unknown:
            return .init(title: "Something Went Wrong",
                         message: "The archive couldn’t be opened.",
                         sfSymbol: "exclamationmark.triangle")
        }
    }

    /// Raw text for the collapsible detail / bug reports only.
    var technicalDetail: String? {
        switch self {
        case .readerFailed(let e), .unknown(let e):
            return String(describing: e)
        case .schemaTooNew(let found, let supported),
             .schemaTooOld(let found, let supported):
            return "Schema version \(found), supported \(supported)."
        default:
            return nil
        }
    }

    struct Action {
        enum Kind { case retry, openSettings, openHelp, openAppStore, reportIssue }
        let title: String
        let kind: Kind
    }

    /// The primary CTA shown beneath the error title. Routed by case to
    /// "what can the user actually do." Help / App Store / report-issue
    /// kinds are no-ops until the corresponding resources exist —
    /// ErrorView's `onAction` handler decides what to do with each.
    var primaryAction: Action? {
        switch self {
        case .iCloudSignedOut, .iCloudDriveDisabled:
            return .init(title: "Open Settings", kind: .openSettings)
        case .networkUnavailable, .downloadStalled:
            return .init(title: "Try Again", kind: .retry)
        case .downloadFailed(let partial):
            return .init(title: partial ? "Resume" : "Try Again", kind: .retry)
        case .archiveCorrupt, .schemaTooOld:
            return .init(title: "How to Re-create", kind: .openHelp)
        case .schemaTooNew:
            return .init(title: "Update App", kind: .openAppStore)
        case .readerFailed, .unknown:
            return .init(title: "Try Again", kind: .retry)
        }
    }

    /// Best-effort classification of an unknown underlying error into one
    /// of the named cases. Falls back to `.readerFailed`.
    static func classify(_ error: Error) -> ArchiveError {
        if let already = error as? ArchiveError {
            return already
        }
        if let readerErr = error as? ArchiveReaderError {
            switch readerErr {
            case .schemaTooNew(let found, let max):
                return .schemaTooNew(found: found, supported: max)
            case .openFailed:
                return .archiveCorrupt
            }
        }
        let ns = error as NSError
        let domainLower = ns.domain.lowercased()
        // SQLITE_CANTOPEN / SQLITE_CORRUPT / SQLITE_NOTADB all map to "the
        // bundle on disk is unreadable" — same user-facing remedy.
        if domainLower.contains("sqlite") || domainLower.contains("grdb") {
            return .archiveCorrupt
        }
        return .readerFailed(underlying: error)
    }
}
