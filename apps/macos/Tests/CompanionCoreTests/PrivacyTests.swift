import XCTest
@testable import CompanionCore

final class PrivacyTests: XCTestCase {
    func testPrivacyIsOffAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("privacy.json")
        XCTAssertEqual(PrivacySettings.load(from: url), PrivacySettings())
        try PrivacySettings().save(to: url)
        XCTAssertEqual(PrivacySettings.load(from: url), PrivacySettings())
        try Data("invalid".utf8).write(to: url)
        XCTAssertEqual(PrivacySettings.load(from: url), PrivacySettings())
    }
}
