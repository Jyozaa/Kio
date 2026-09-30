import XCTest
@testable import CompanionCore

final class SpeechSilenceTests: XCTestCase {
    func testSilenceBeforeSpeechDoesNotEndUtteranceEarly() {
        let start = Date(timeIntervalSince1970: 100)
        var detector = SpeechSilenceDetector(startedAt: start)
        XCTAssertFalse(detector.shouldFinish(now: start.addingTimeInterval(5), levelDB: -80))
        XCTAssertTrue(detector.shouldFinish(now: start.addingTimeInterval(8), levelDB: -80))
    }

    func testTrailingSilenceEndsOnlyAfterSpeech() {
        let start = Date(timeIntervalSince1970: 100)
        var detector = SpeechSilenceDetector(startedAt: start, trailingSilence: 1.0)
        XCTAssertFalse(detector.shouldFinish(now: start.addingTimeInterval(1), levelDB: -30))
        XCTAssertFalse(detector.shouldFinish(now: start.addingTimeInterval(1.9), levelDB: -80))
        XCTAssertTrue(detector.shouldFinish(now: start.addingTimeInterval(2.1), levelDB: -80))
    }

    func testMaximumDurationAndInvalidMeterReadFailSafe() {
        let start = Date(timeIntervalSince1970: 100)
        var detector = SpeechSilenceDetector(startedAt: start, maximumDuration: 10, noSpeechTimeout: 20)
        XCTAssertFalse(detector.shouldFinish(now: start.addingTimeInterval(9), levelDB: .nan))
        XCTAssertTrue(detector.shouldFinish(now: start.addingTimeInterval(10), levelDB: .nan))
    }
}
