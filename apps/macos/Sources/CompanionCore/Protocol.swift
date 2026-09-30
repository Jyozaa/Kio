import Foundation

public struct Message: Codable, Equatable, Sendable {
    public var version: Int = protocolVersion
    public var kind: String
    public var task_id: String
    public var text: String
    public var status: String
    public var target: String?
    // Deprecated decode-only compatibility with pre-autonomy helpers.
    public var approval_id: String?
    public var answer: ObservationAnswerPayload?
    public var error_code: String?
    public init(kind: String, taskID: String, text: String = "", status: String = "", target: String? = nil, approvalID: String? = nil, answer: ObservationAnswerPayload? = nil, errorCode: String? = nil) {
        self.kind = kind; self.task_id = taskID; self.text = text; self.status = status; self.target = target; self.approval_id = approvalID
        self.answer = answer
        self.error_code = errorCode
    }
    public func encoded() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(10)
        return data
    }
    public static func decode(_ data: Data) throws -> Message {
        guard data.count <= 65536 else { throw ProtocolError.invalid }
        let message = try JSONDecoder().decode(Message.self, from: data)
        let validErrorCode = message.error_code.map {
            !$0.isEmpty && $0.count <= 80 && $0.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_").contains($0)
            }
        } ?? true
        guard message.version == protocolVersion,
              ["command", "event", "confirmation_required", "result", "answer", "error", "cancel", "health", "approve"].contains(message.kind),
              !message.task_id.isEmpty, message.task_id.count <= 128,
              validErrorCode, message.error_code == nil || message.kind == "error" else {
            throw ProtocolError.invalid
        }
        return message
    }
}
public enum ProtocolError: Error { case invalid }
public struct ObservationAnswerPayload: Codable, Equatable, Sendable {
    public var answer: String
    public var confidence: Double
    public var source_app: String
    public var source_window: String
    public var evidence: [String]
    public init(answer: String, confidence: Double, sourceApp: String, sourceWindow: String, evidence: [String]) {
        self.answer = answer; self.confidence = confidence; self.source_app = sourceApp
        self.source_window = sourceWindow; self.evidence = evidence
    }
}
public enum TaskState: String, Sendable {
    case idle, working, needsUser, completed, answered, error
}

public struct TaskStatus: Sendable {
    public private(set) var taskID: String?
    public private(set) var state: TaskState = .idle
    public private(set) var text = "Ready."
    public private(set) var answer: ObservationAnswerPayload?
    public private(set) var errorCode: String?
    public init() {}
    public mutating func start(_ id: String) {
        taskID = id; state = .working; text = "Starting…"; answer = nil; errorCode = nil
    }
    public mutating func fail(_ reason: String) { state = .error; text = reason; taskID = nil; answer = nil; errorCode = nil }
    public mutating func reset() { taskID = nil; state = .idle; text = "Ready."; answer = nil; errorCode = nil }
    public mutating func apply(_ message: Message) {
        guard message.task_id == taskID else { return }
        let browserMarker = "[KIO_BROWSER_ACCESS_REQUIRED] "
        text = message.text.hasPrefix(browserMarker)
            ? String(message.text.dropFirst(browserMarker.count))
            : message.text
        if message.kind == "answer" {
            guard let answer = message.answer, answer.answer == message.text,
                  !answer.answer.isEmpty, answer.answer.count <= 500,
                  answer.confidence.isFinite, (0...1).contains(answer.confidence),
                  answer.source_app.count <= 200, answer.source_window.count <= 200,
                  answer.evidence.count <= 8, answer.evidence.allSatisfy({ $0.count <= 200 }) else {
                state = .error; taskID = nil; text = "Kio couldn't show the answer."; return
            }
            self.answer = answer
            state = .answered; taskID = nil
            return
        }
        switch message.kind {
        case "confirmation_required":
            state = .needsUser; taskID = nil
            text = "Legacy approval response is unsupported. Update the helper."
        case "error": state = .error; taskID = nil; errorCode = message.error_code
        case "event": state = message.status == "needs_user" ? .needsUser : .working
        case "result":
            state = message.status == "completed" ? .completed :
                (message.status == "cancelled" ? .idle : .needsUser)
            taskID = nil
        default: break
        }
    }
}
