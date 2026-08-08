@testable import LedgeCore
import XCTest

final class ScaffoldTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(LedgeCoreInfo.version, "0.1.0")
    }

    func testFixtureVaultExists() {
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: Fixtures.vault.path, isDirectory: &isDir),
            "fixture vault missing at \(Fixtures.vault.path)"
        )
        XCTAssertTrue(isDir.boolValue)
    }

    func testFakeClaudeIsExecutable() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Fixtures.fakeClaude.path))
    }
}
