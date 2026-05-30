import XCTest
@testable import iMessageArchiver

final class TarReaderTests: XCTestCase {
    func testExtractFromFixture() throws {
        // Fixture files are bundled individually (see ios/project.yml).
        // The .tar is what TarReader actually needs; reassemble a bundle
        // dir in tmp so TarReader(bundleURL:) can find it.
        let bundle = Bundle(for: type(of: self))
        guard let tarURL = bundle.url(forResource: "attachments", withExtension: "tar"),
              let archiveURL = bundle.url(forResource: "archive", withExtension: "sqlite"),
              let manifestURL = bundle.url(forResource: "manifest", withExtension: "json") else {
            throw XCTSkip(
                "fixture files not bundled — run generate_fixture.sh"
            )
        }

        let tmpDir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bURL = tmpDir.appendingPathComponent("tiny.imarchive", isDirectory: true)
        try FileManager.default.createDirectory(at: bURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: tarURL,
                                          to: bURL.appendingPathComponent("attachments.tar"))
        try FileManager.default.copyItem(at: archiveURL,
                                          to: bURL.appendingPathComponent("archive.sqlite"))
        try FileManager.default.copyItem(at: manifestURL,
                                          to: bURL.appendingPathComponent("manifest.json"))
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let copiedTar = bURL.appendingPathComponent("attachments.tar")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: copiedTar.path),
            "tiny.imarchive/attachments.tar not present after reassembly"
        )
        XCTAssertNoThrow(try TarReader(bundleURL: bURL))
    }

    func testMissingTarThrows() {
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist.imarchive")
        XCTAssertThrowsError(try TarReader(bundleURL: bogus))
    }
}
