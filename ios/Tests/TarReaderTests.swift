import XCTest
@testable import iMessageArchiver

final class TarReaderTests: XCTestCase {
    func testExtractFromFixture() throws {
        guard let bundleURL = Bundle(for: type(of: self))
            .url(forResource: "tiny", withExtension: "imarchive")
        else {
            throw XCTSkip("tiny.imarchive fixture not found")
        }

        let tarURL = bundleURL.appendingPathComponent("attachments.tar")
        guard FileManager.default.fileExists(atPath: tarURL.path) else {
            throw XCTSkip("attachments.tar not present in fixture")
        }

        // Just verify TarReader initialises without throwing.
        XCTAssertNoThrow(try TarReader(bundleURL: bundleURL))
    }

    func testMissingTarThrows() {
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist.imarchive")
        XCTAssertThrowsError(try TarReader(bundleURL: bogus))
    }
}
