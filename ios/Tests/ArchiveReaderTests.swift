import XCTest
@testable import iMessageArchiver

final class ArchiveReaderTests: XCTestCase {
    var bundleURL: URL!
    var reader: ArchiveReader!

    override func setUpWithError() throws {
        // tiny.imarchive must be generated before running this suite —
        // either locally via ios/Tests/Fixtures/generate_fixture.sh or by
        // CI's "Generate tiny.imarchive bundle for iOS tests" step.
        //
        // Previously this used XCTSkipIf, which made CI silently pass even
        // when the fixture was missing. Now we assert hard so a missing
        // fixture is loud, not silent.
        bundleURL = Bundle(for: type(of: self))
            .url(forResource: "tiny", withExtension: "imarchive")
        XCTAssertNotNil(
            bundleURL,
            "tiny.imarchive fixture not bundled. Run ios/Tests/Fixtures/generate_fixture.sh "
                + "before re-running the test suite."
        )
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
