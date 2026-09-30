import Foundation

public enum VoicePhase: String, Sendable { case ready = "Ready", permission = "Microphone permission…", listening = "Listening…", transcribing = "Transcribing…", review = "Review transcript", failed = "Voice unavailable" }

public struct VoiceState: Sendable {
    public private(set) var phase: VoicePhase = .ready
    public private(set) var generation = UUID()
    public private(set) var transcript = ""
    public private(set) var error = ""
    public init() {}
    @discardableResult public mutating func begin() -> UUID {
        generation = UUID(); phase = .permission; transcript = ""; error = ""
        return generation
    }
    public mutating func recording(_ token: UUID) { if generation == token { phase = .listening } }
    public mutating func partial(_ text: String, token: UUID) {
        guard generation == token, phase == .listening else { return }
        transcript = String(Self.clean(text).prefix(4000))
    }
    public mutating func transcribing(_ token: UUID) { if generation == token { phase = .transcribing } }
    public mutating func finish(_ text: String, token: UUID) {
        guard generation == token else { return }
        transcript = String(Self.clean(text).prefix(4000))
        if transcript.isEmpty { fail("No speech detected.", token: token) }
        else { phase = .review }
    }
    public mutating func submitted(token: UUID) {
        if generation == token { phase = .ready }
    }
    public mutating func fail(_ message: String, token: UUID) {
        guard generation == token else { return }
        error = message; phase = .failed
    }
    public mutating func cancel() { generation = UUID(); phase = .ready; transcript = ""; error = "" }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "[BLANK_AUDIO]", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
