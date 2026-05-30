import XCTest
@testable import iMessageArchiver

final class ArchiveReaderTests: XCTestCase {
    var bundleURL: URL!
    var workingBundleURL: URL!
    var reader: ArchiveReader!

    override func setUpWithError() throws {
        // tiny.imarchive must be generated before running this suite —
        // either locally via ios/Tests/Fixtures/generate_fixture.sh or by
        // CI's "Generate tiny.imarchive bundle for iOS tests" step.
        bundleURL = Bundle(for: type(of: self))
            .url(forResource: "tiny", withExtension: "imarchive")
        XCTAssertNotNil(
            bundleURL,
            "tiny.imarchive fixture not bundled. Run ios/Tests/Fixtures/generate_fixture.sh "
                + "before re-running the test suite."
        )

        // Copy the fixture out of the read-only test bundle into the
        // writable tmp dir. SQLite/GRDB tries to create -wal/-shm next
        // to the database on open — even with config.readonly = true —
        // and fails with SQLITE_CANTOPEN against the bundle's resource
        // directory (which isn't writable on iOS simulators). The
        // production app's bundle lives in iCloud Drive, which IS
        // writable, so the same code path works there.
        let tmpDir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        workingBundleURL = tmpDir.appendingPathComponent("tiny.imarchive", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundleURL, to: workingBundleURL)

        // Diagnostic: surface the actual bundle contents in the test
        // failure message so we can see whether the folder reference is
        // empty (xcodegen / Xcode misbundling), whether archive.sqlite
        // is present, or whether something else broke between bundle
        // generation and test runtime.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: workingBundleURL,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let listing = contents.map { url -> String in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return "\(url.lastPathComponent) (\(size) bytes)"
        }.joined(separator: ", ")
        XCTAssertTrue(
            contents.contains { $0.lastPathComponent == "archive.sqlite" },
            "Copied bundle missing archive.sqlite. Contents: [\(listing)]. " +
            "Source bundle URL: \(bundleURL.path)"
        )

        reader = try ArchiveReader(bundleURL: workingBundleURL)
    }

    override func tearDownWithError() throws {
        if let workingBundleURL {
            try? FileManager.default.removeItem(at: workingBundleURL.deletingLastPathComponent())
        }
    }

    func testManifestLoads() throws {
        XCTAssertGreaterThan(reader.manifest.schemaVersion, 0)
    }

    func testChatsNotEmpty() async throws {
        let chats = try await reader.chats()
        XCTAssertFalse(chats.isEmpty, "Expected at least one chat in fixture")
    }

    func testMessagesInFirstChat() async throws {
        let chats = try await reader.chats()
        guard let first = chats.first else { return }
        let messages = try await reader.messages(in: first.chatGuid, limit: 50)
        XCTAssertFalse(messages.isEmpty)
    }

    func testSearchReturnsResults() async throws {
        let results = try await reader.search(query: "hello")
        // May or may not match depending on fixture content — just verify it doesn't throw.
        XCTAssertNotNil(results)
    }
}
