import Foundation

/// Hardware-format facts kept separate from AVAudioFormat so selection can be tested without a microphone.
public struct CueAudioFormatDescriptor: Sendable, Equatable {
    public let sampleRate: Double
    public let channelCount: UInt32

    public init(sampleRate: Double, channelCount: UInt32) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public var isValid: Bool { sampleRate.isFinite && sampleRate > 0 && channelCount > 0 }
}

public enum CueAudioFormatPolicy {
    /// Preserve the device rate and use mono processing whenever a valid mono format can be made.
    public static func captureFormat(for hardware: CueAudioFormatDescriptor) -> CueAudioFormatDescriptor? {
        guard hardware.isValid else { return nil }
        return CueAudioFormatDescriptor(sampleRate: hardware.sampleRate,
                                        channelCount: hardware.channelCount > 1 ? 1 : hardware.channelCount)
    }

    /// Analyzer formats must come from SpeechAnalyzer's supported-format query; never assume capture is compatible.
    public static func analyzerFormat(preferred: CueAudioFormatDescriptor?) -> CueAudioFormatDescriptor? {
        guard let preferred, preferred.isValid else { return nil }
        return preferred
    }
}

public enum CueSpeechBackendKind: Sendable, Equatable {
    case speechAnalyzer
    case speechRecognizer
}

public enum CueSpeechBackendPolicy {
    public static func select(modernPrepared: Bool, legacyAvailable: Bool) -> CueSpeechBackendKind? {
        if modernPrepared { return .speechAnalyzer }
        if legacyAvailable { return .speechRecognizer }
        return nil
    }
}

public enum CueAudioSessionPhase: String, Sendable, Equatable {
    case idle, prepared, starting, running, stopping, stopped
}

/// Pure session bookkeeping shared by Cue startup and its non-live lifecycle tests.
public struct CueAudioSessionLifecycle: Sendable, Equatable {
    public private(set) var phase: CueAudioSessionPhase = .idle
    public private(set) var tapInstalled = false
    public private(set) var generation = 0

    public init() {}

    public mutating func markPrepared() {
        if phase == .idle || phase == .stopped { phase = .prepared }
    }

    @discardableResult
    public mutating func beginStart() -> Int? {
        guard phase != .starting, phase != .running else { return nil }
        generation &+= 1
        phase = .starting
        tapInstalled = false
        return generation
    }

    public func isCurrent(_ attempt: Int) -> Bool {
        generation == attempt && (phase == .starting || phase == .running)
    }

    @discardableResult
    public mutating func installTap(for attempt: Int) -> Bool {
        guard generation == attempt, phase == .starting, !tapInstalled else { return false }
        tapInstalled = true
        return true
    }

    @discardableResult
    public mutating func didStart(_ attempt: Int) -> Bool {
        guard generation == attempt, phase == .starting, tapInstalled else { return false }
        phase = .running
        return true
    }

    @discardableResult
    public mutating func beginFallback(_ attempt: Int) -> Bool {
        guard generation == attempt, phase == .running else { return false }
        phase = .starting
        tapInstalled = false
        return true
    }

    public mutating func failStart(_ attempt: Int) {
        guard generation == attempt else { return }
        tapInstalled = false
        phase = .stopped
    }

    public mutating func removeTap(_ attempt: Int) {
        guard generation == attempt else { return }
        tapInstalled = false
    }

    public mutating func stop() {
        phase = .stopping
        tapInstalled = false
        generation &+= 1
        phase = .stopped
    }
}
