import XCTest
@testable import CompanionCore

final class VoiceTests: XCTestCase {
    func testRecordingAndReview() {
        var state = VoiceState(); let token = state.begin()
        XCTAssertEqual(state.phase, .permission)
        state.recording(token); XCTAssertEqual(state.phase, .listening)
        state.transcribing(token); XCTAssertEqual(state.phase, .transcribing)
        state.finish(" Open Calculator \n", token: token)
        XCTAssertEqual(state.phase, .review); XCTAssertEqual(state.transcript, "Open Calculator")
    }
    func testCancelRecordingAndTranscription() {
        for transcribing in [false, true] {
            var state = VoiceState(); let token = state.begin(); state.recording(token)
            if transcribing { state.transcribing(token) }
            state.cancel(); state.finish("stale command", token: token)
            XCTAssertEqual(state.phase, .ready); XCTAssertEqual(state.transcript, "")
        }
    }
    func testEmptyAndUnavailable() {
        var state = VoiceState(); let token = state.begin()
        state.finish(" \n", token: token); XCTAssertEqual(state.phase, .failed)
        state.fail("No microphone available.", token: token)
        XCTAssertEqual(state.error, "No microphone available.")
        state.cancel(); state.fail("stale error", token: token)
        XCTAssertEqual(state.phase, .ready)
    }

    func testWhisperBlankAudioMarkerIsNotSpeech() {
        var state = VoiceState(); let token = state.begin()
        state.recording(token); state.transcribing(token)
        state.finish(" [BLANK_AUDIO] ", token: token)
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.error, "No speech detected.")
    }

    func testSubmittedTranscriptLeavesReviewAndPreservesText() {
        var state = VoiceState()
        let token = state.begin()
        state.recording(token)
        state.transcribing(token)
        state.finish("Open Notes", token: token)
        state.submitted(token: token)
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.transcript, "Open Notes")
    }
}
