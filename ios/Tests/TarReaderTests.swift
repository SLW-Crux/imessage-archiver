import XCTest
@testable import iMessageArchiver

final class TarReaderTests: XCTestCase {
    func testExtractFromFixture() throws {
        let bundleURL = Bundle(for: type(of: self))
            .url(forResource: "tiny", withExtension: "imarchive")
        // Hard-assert the fixture so CI fails loudly if it's missing.
        XCTAssertNotNil(
            bundleURL,
            "tiny.imarchive fixture missing — run generate_fixture.sh"
        )
        let bURL = try XCTUnwrap(bundleURL)

        let tarURL = bURL.appendingPathComponent("attachments.tar")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tarURL.path),
            "tiny.imarchive/attachments.tar not present"
        )
        XCTAssertNoThrow(try TarReader(bundleURL: bURL))
    }

    func testMissingTarThrows() {
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist.imarchive")
        XCTAssertThrowsError(try TarReader(bundleURL: bogus))
    }
}
