import XCTest
@testable import CompanionCore
final class ProtocolTests: XCTestCase {
    func testRoundTrip() throws {
        let message = Message(kind: "command", taskID: "abc", text: "hello\n你好")
        XCTAssertEqual(try Message.decode(message.encoded()), message)
    }
    func testTypedQuestionAnswerLifecycle() throws {
        let payload = ObservationAnswerPayload(
            answer: "The mute control is at the bottom-left.", confidence: 0.92,
            sourceApp: "Discord", sourceWindow: "Discord", evidence: ["control=Mute"]
        )
        let message = Message(kind: "answer", taskID: "question", text: payload.answer,
                              status: "answered", answer: payload)
        XCTAssertEqual(try Message.decode(message.encoded()), message)
        var state = TaskStatus(); state.start("question"); state.apply(message)
        XCTAssertEqual(state.state, .answered)
        XCTAssertEqual(state.answer?.source_app, "Discord")
        XCTAssertNil(state.taskID)
    }
    func testLegacyApprovalDoesNotGrantAuthority() {
        var state = TaskStatus(); state.start("task")
        state.apply(Message(kind: "confirmation_required", taskID: "task", approvalID: "once"))
        XCTAssertNil(state.taskID)
        XCTAssertEqual(state.state, .needsUser)
        state.apply(Message(kind: "result", taskID: "task", status: "cancelled"))
        XCTAssertNil(state.taskID)
    }
    func testMalformed() {
        for value in ["{}", "garbage", "null", "[]"] {
            XCTAssertThrowsError(try Message.decode(Data(value.utf8)))
        }
        var message = Message(kind: "command", taskID: "abc")
        message.version = 2
        XCTAssertThrowsError(try Message.decode(message.encoded()))
    }
    func testTaskLifecycleAndForeignEvents() {
        var state = TaskStatus()
        state.start("a")
        state.apply(Message(kind: "result", taskID: "b", status: "completed"))
        XCTAssertEqual(state.state, .working)
        state.apply(Message(kind: "event", taskID: "a", text: "Looking…", status: "observing"))
        XCTAssertEqual(state.text, "Looking…")
        state.apply(Message(kind: "result", taskID: "a", status: "completed"))
        XCTAssertEqual(state.state, .completed)
        XCTAssertNil(state.taskID)
    }

    func testBrowserAccessMarkerIsShownAsUserFacingCopy() {
        var state = TaskStatus(); state.start("browser")
        state.apply(Message(
            kind: "result", taskID: "browser",
            text: "[KIO_BROWSER_ACCESS_REQUIRED] Kio needs one-time browser access to work directly with Chrome.",
            status: "needs_user"
        ))
        XCTAssertEqual(state.state, .needsUser)
        XCTAssertEqual(state.text, "Kio needs one-time browser access to work directly with Chrome.")
    }
    func testStructuredErrorKeepsDiagnosticCodeOutOfUserCopy() {
        let message = Message(
            kind: "error",
            taskID: "diagnostic",
            text: "The app changed while Kio was working. Try again.",
            status: "error",
            errorCode: "stale_state"
        )
        var state = TaskStatus()
        state.start("diagnostic")
        state.apply(message)
        XCTAssertEqual(state.state, .error)
        XCTAssertEqual(state.text, "The app changed while Kio was working. Try again.")
        XCTAssertEqual(state.errorCode, "stale_state")
        XCTAssertEqual(try Message.decode(message.encoded()), message)
    }
    func testCancellationAndConfirmation() {
        var state = TaskStatus(); state.start("a")
        state.apply(Message(kind: "confirmation_required", taskID: "a"))
        XCTAssertEqual(state.state, .needsUser)
        XCTAssertNil(state.taskID)
        state.reset(); state.start("a-cancel")
        state.apply(Message(kind: "result", taskID: "a-cancel", status: "cancelled"))
        XCTAssertEqual(state.state, .idle)
        state.start("b"); state.apply(Message(kind: "error", taskID: "b"))
        XCTAssertEqual(state.state, .error)
        state.reset(); XCTAssertEqual(state.state, .idle)
    }
}
