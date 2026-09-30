import Foundation

/// Local amplitude-based end-of-utterance gate; it stores no audio or speech content.
public struct SpeechSilenceDetector: Sendable {
    private let startedAt: Date
    private let thresholdDB: Double
    private let trailingSilence: TimeInterval
    private let maximumDuration: TimeInterval
    private let noSpeechTimeout: TimeInterval
    private var speechDetected = false
    private var lastSpeechAt: Date?

    public init(
        startedAt: Date = Date(),
        thresholdDB: Double = -45,
        trailingSilence: TimeInterval = 1.0,
        maximumDuration: TimeInterval = 30,
        noSpeechTimeout: TimeInterval = 8
    ) {
        self.startedAt = startedAt
        self.thresholdDB = thresholdDB
        self.trailingSilence = trailingSilence
        self.maximumDuration = maximumDuration
        self.noSpeechTimeout = noSpeechTimeout
    }

    /// Returns true after trailing silence, a hard duration bound, or prolonged no-speech.
    public mutating func shouldFinish(now: Date, levelDB: Double) -> Bool {
        if levelDB.isFinite, levelDB > thresholdDB {
            speechDetected = true
            lastSpeechAt = now
        }
        let duration = now.timeIntervalSince(startedAt)
        if duration >= maximumDuration { return true }
        if speechDetected, let lastSpeechAt {
            return now.timeIntervalSince(lastSpeechAt) >= trailingSilence
        }
        return duration >= noSpeechTimeout
    }
}
