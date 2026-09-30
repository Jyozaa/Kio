import XCTest
@testable import CompanionCore

final class StreamingAudioLevelTests: XCTestCase {
    func testPublishesLatestBoundedLevel() {
        let meter = StreamingAudioLevel()
        XCTAssertEqual(meter.load(), -160)

        meter.publish(-37.5)
        XCTAssertEqual(meter.load(), -37.5)

        meter.publish(8)
        XCTAssertEqual(meter.load(), 0)

        meter.publish(.nan)
        XCTAssertEqual(meter.load(), -160)
    }

    func testConcurrentAudioWritesAndUiReadsRemainSafe() {
        let meter = StreamingAudioLevel()
        let finished = DispatchGroup()
        finished.enter()

        DispatchQueue.global().async {
            for index in 0..<10_000 {
                meter.publish(Double(index % 161) - 160)
            }
            finished.leave()
        }

        while finished.wait(timeout: .now()) == .timedOut {
            let current = meter.load()
            XCTAssertTrue((-160...0).contains(current))
        }
        XCTAssertTrue((-160...0).contains(meter.load()))
    }
}
