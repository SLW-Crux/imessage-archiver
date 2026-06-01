#if os(macOS)
import Foundation
import Contacts

/// Resolves a phone-number / email handle to a display name via
/// `CNContactStore`. Falls back to returning the raw handle when:
///
/// - the user hasn't granted Contacts authorization
/// - no matching contact exists
/// - the Contacts framework throws (which it occasionally does on
///   stripped-down macOS runtime configurations)
///
/// Caches results per process lifetime so an archive run of N messages
/// doesn't fire N+ identical CNContactStore queries.
///
/// Port of `src/imessage_archiver/db/contacts.py`.
actor ContactsResolver {

    /// Shared resolver. Use this for archiver runs so the LRU cache
    /// survives across calls.
    static let shared = ContactsResolver()

    private let store: CNContactStore
    private var authorized: Bool?
    private var cache: [String: String] = [:]
    private let cacheCapacity = 2048

    // Computed (not stored static) because [CNKeyDescriptor] isn't
    // Sendable; a static let would fire a Swift 6 concurrency-safety
    // warning. The cost of recomputing is trivial — four bridged-string
    // casts.
    private static var keysToFetch: [CNKeyDescriptor] {
        [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
    }

    init() {
        self.store = CNContactStore()
    }

    /// Probe `CNContactStore` authorization. Mirrors the Python guard:
    /// only an `.authorized` status counts; `.notDetermined` would hang
    /// a CNContactStore query waiting for a permission prompt that may
    /// never appear (e.g. CI runner with no GUI session).
    func isAuthorized() -> Bool {
        if let cached = authorized { return cached }
        let status = CNContactStore.authorizationStatus(for: .contacts)
        let ok = (status == .authorized)
        authorized = ok
        return ok
    }

    /// Request Contacts access if not yet determined. Returns the final
    /// authorization state. Call once at archive start; subsequent
    /// `resolve(_:)` calls reuse the result.
    func requestAccessIfNeeded() async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized {
            authorized = true
            return true
        }
        if status == .notDetermined {
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            authorized = granted
            return granted
        }
        authorized = false
        return false
    }

    /// Resolve `handle` (phone or email) to a display name. Returns the
    /// original `handle` string if no match is found or if Contacts is
    /// unavailable.
    func resolve(_ handle: String) -> String {
        guard !handle.isEmpty else { return handle }
        if let cached = cache[handle] { return cached }
        guard isAuthorized() else { return handle }

        let resolved = query(handle: handle)
        // Cap the cache at `cacheCapacity` entries — simple FIFO eviction
        // is sufficient for archiving (no hot/cold distinction within a
        // single run).
        if cache.count >= cacheCapacity {
            if let firstKey = cache.keys.first {
                cache.removeValue(forKey: firstKey)
            }
        }
        cache[handle] = resolved
        return resolved
    }

    /// Reset the cache. Useful for tests / repeated archive runs in the
    /// same process.
    func clearCache() {
        cache.removeAll()
        authorized = nil
    }

    // MARK: - Internal

    private func query(handle: String) -> String {
        let predicate: NSPredicate
        if handle.contains("@") {
            predicate = CNContact.predicateForContacts(matchingEmailAddress: handle)
        } else {
            let phone = CNPhoneNumber(stringValue: handle)
            predicate = CNContact.predicateForContacts(matching: phone)
        }

        let contacts: [CNContact]
        do {
            contacts = try store.unifiedContacts(
                matching: predicate,
                keysToFetch: Self.keysToFetch
            )
        } catch {
            return handle
        }
        guard let first = contacts.first else { return handle }
        let composed = "\(first.givenName) \(first.familyName)"
            .trimmingCharacters(in: .whitespaces)
        return composed.isEmpty ? handle : composed
    }
}

#endif
