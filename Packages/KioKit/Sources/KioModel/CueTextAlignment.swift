import Foundation

public struct CueToken: Sendable, Equatable {
    public let text: String
    public let range: NSRange
}

/// Monotonic word alignment for revised Speech framework partial transcripts.
/// Script ranges are retained so views can highlight the original punctuation/casing.
public struct CueTextAlignment: Sendable, Equatable {
    public let tokens: [CueToken]
    public private(set) var confirmedReadPosition = 0
    public private(set) var generation = 0
    private var pendingLargeJumpPosition: Int?
    private var pendingLargeJumpConfirmations = 0

    public init(script: String) {
        let ns = script as NSString
        let pattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)?")
        tokens = pattern.matches(in: script, range: NSRange(location: 0, length: ns.length)).map { match in
            CueToken(text: Self.normalize(ns.substring(with: match.range)), range: match.range)
        }
    }

    @discardableResult
    public mutating func consume(_ transcript: String, confidence: Float, generation callbackGeneration: Int? = nil) -> Int {
        if let callbackGeneration, callbackGeneration != generation { return confirmedReadPosition }
        guard confidence >= 0.30, !tokens.isEmpty else { return confirmedReadPosition }
        let heard = Self.words(transcript)
        guard !heard.isEmpty else { return confirmedReadPosition }
        let low = max(0, confirmedReadPosition - 2)
        let high = min(tokens.count, confirmedReadPosition + 42)
        var bestEnd = confirmedReadPosition
        var bestScore = 0
        for start in low..<high {
            for heardStart in heard.indices {
                var matched = 0
                while heardStart + matched < heard.count, start + matched < tokens.count,
                      tokens[start + matched].text == heard[heardStart + matched] { matched += 1 }
                if matched > bestScore {
                    bestScore = matched
                    bestEnd = start + matched
                }
            }
        }
        guard bestScore > 0 else { return confirmedReadPosition }
        let target = max(confirmedReadPosition, bestEnd)
        let jump = target - confirmedReadPosition
        if jump > 8 {
            if let pendingLargeJumpPosition, abs(pendingLargeJumpPosition - target) <= 2 {
                pendingLargeJumpConfirmations += 1
                self.pendingLargeJumpPosition = target
            }
            else { pendingLargeJumpPosition = target; pendingLargeJumpConfirmations = 1 }
            guard pendingLargeJumpConfirmations >= 2 else { return confirmedReadPosition }
        }
        pendingLargeJumpPosition = nil
        pendingLargeJumpConfirmations = 0
        confirmedReadPosition = target
        return target
    }

    @discardableResult
    public mutating func jump(to tokenIndex: Int) -> Int {
        confirmedReadPosition = min(tokens.count, max(0, tokenIndex))
        generation &+= 1
        pendingLargeJumpPosition = nil
        pendingLargeJumpConfirmations = 0
        return confirmedReadPosition
    }

    public var isFinished: Bool { !tokens.isEmpty && confirmedReadPosition >= tokens.count }

    public var upcomingContextWords: [String] {
        var seen = Set<String>()
        return tokens.dropFirst(confirmedReadPosition).prefix(80).map(\.text).filter { word in
            guard word.count >= 5, seen.insert(word).inserted else { return false }
            return true
        }.prefix(32).map { $0 }
    }

    public static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    public static func words(_ text: String) -> [String] {
        let ns = text as NSString
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)?")
        let fillers: Set<String> = ["um", "uh", "erm", "er"]
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { normalize(ns.substring(with: $0.range)) }
            .filter { !fillers.contains($0) }
    }
}

public struct CueClassicClock: Sendable, Equatable {
    public private(set) var position: Double = 0
    public init() {}

    public mutating func advance(elapsed: TimeInterval, wordsPerMinute: Double, totalWords: Int, paused: Bool) -> Double {
        guard !paused, totalWords > 0, elapsed.isFinite, wordsPerMinute.isFinite else { return position }
        position = min(Double(totalWords), max(position, position + max(0, elapsed) * max(30, min(400, wordsPerMinute)) / 60))
        return position
    }
}

public struct CueVoiceActivityState: Sendable, Equatable {
    public private(set) var isSpeaking = false
    public init() {}

    public mutating func update(power: Float, threshold: Float = 0.035) -> Bool {
        isSpeaking = power.isFinite && power >= threshold
        return isSpeaking
    }
}
