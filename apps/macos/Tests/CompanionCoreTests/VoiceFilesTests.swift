import XCTest
@testable import CompanionCore

final class VoiceFilesTests: XCTestCase {
    func testCrashCleanupPreservesActiveAndUnrelatedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent("KioVoice-123-test")
        let active = root.appendingPathComponent("KioVoice-456-test")
        let other = root.appendingPathComponent("OtherRecording")
        for path in [stale, active, other] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
        VoiceTemporaryFiles.removeAbandoned(root: root, isAlive: { $0 == 456 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        let created = try VoiceTemporaryFiles.create(root: root)
        let mode = try FileManager.default.attributesOfItem(atPath: created.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }
}
