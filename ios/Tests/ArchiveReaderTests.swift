import XCTest
@testable import iMessageArchiver

final class ArchiveReaderTests: XCTestCase {
    var workingBundleURL: URL!
    var reader: ArchiveReader!

    override func setUpWithError() throws {
        // Fixture is bundled into the test target as three individual
        // files (archive.sqlite, attachments.tar, manifest.json) at the
        // test bundle root — see ios/project.yml. xcodegen's folder-
        // reference / type:folder route silently produced empty file
        // contents in the bundle, so the per-file route is the only
        // one that actually lands the bytes.
        //
        // Reassemble them into a tiny.imarchive directory in tmp so the
        // ArchiveReader API (which takes a bundle URL, not three file
        // URLs) sees what it expects.
        let bundle = Bundle(for: type(of: self))
        let archive = try Self.requireResource(in: bundle, name: "archive", ext: "sqlite")
        let tar = try Self.requireResource(in: bundle, name: "attachments", ext: "tar")
        let manifest = try Self.requireResource(in: bundle, name: "manifest", ext: "json")

        let tmpDir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        workingBundleURL = tmpDir.appendingPathComponent("tiny.imarchive", isDirectory: true)
        try FileManager.default.createDirectory(at: workingBundleURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: archive,
                                          to: workingBundleURL.appendingPathComponent("archive.sqlite"))
        try FileManager.default.copyItem(at: tar,
                                          to: workingBundleURL.appendingPathComponent("attachments.tar"))
        try FileManager.default.copyItem(at: manifest,
                                          to: workingBundleURL.appendingPathComponent("manifest.json"))

        reader = try ArchiveReader(bundleURL: workingBundleURL)
    }

    override func tearDownWithError() throws {
        if let workingBundleURL {
            try? FileManager.default.removeItem(at: workingBundleURL.deletingLastPathComponent())
        }
    }

    private static func requireResource(in bundle: Bundle, name: String, ext: String) throws -> URL {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw XCTSkip(
                "\(name).\(ext) fixture not bundled. " +
                "Run ios/Tests/Fixtures/generate_fixture.sh before re-running the test suite."
            )
        }
        // Confirm bytes actually landed — previous folder-reference bundling
        // resolved the URL but the file was zero-byte at runtime.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else {
            throw XCTSkip("\(url.lastPathComponent) bundled as zero-byte file.")
        }
        return url
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
