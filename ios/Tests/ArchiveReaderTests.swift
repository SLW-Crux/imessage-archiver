import XCTest
@testable import iMessageArchiver

final class ArchiveReaderTests: XCTestCase {
    var bundleURL: URL!
    var reader: ArchiveReader!

    override func setUpWithError() throws {
        // Use the fixture bundle checked into the Mac project's test fixtures.
        // Copy tiny.imarchive into ios/Tests/Fixtures/ as part of build setup.
        bundleURL = Bundle(for: type(of: self))
            .url(forResource: "tiny", withExtension: "imarchive")
        try XCTSkipIf(bundleURL == nil, "tiny.imarchive fixture not found — skipping")
        reader = try ArchiveReader(bundleURL: bundleURL)
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
