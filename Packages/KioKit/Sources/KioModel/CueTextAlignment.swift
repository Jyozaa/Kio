import Foundation

public struct CueToken: Sendable, Equatable {
    public let text: String
    public let range: NSRange
}

public enum CueTrackingPolicy: Sendable, Equatable {
    case accurate
    case responsive
}

/// Monotonic word alignment for revised Speech framework partial transcripts.
/// Script ranges are retained so views can highlight the original punctuation/casing.
public struct CueTextAlignment: Sendable, Equatable {
    public let tokens: [CueToken]
    public private(set) var confirmedReadPosition = 0
    public private(set) var generation = 0
    private var pendingLargeJumpPosition: Int?
    private var pendingLargeJumpConfirmations = 0
    private var pendingLargeJumpEvidence = ""
    private var recentTranscript = ""

    public init(script: String) {
        let ns = script as NSString
        let pattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)?")
        tokens = pattern.matches(in: script, range: NSRange(location: 0, length: ns.length)).map { match in
            CueToken(text: Self.normalize(ns.substring(with: match.range)), range: match.range)
        }
    }

    @discardableResult
    public mutating func consume(_ transcript: String, confidence: Float, generation callbackGeneration: Int? = nil,
                                 policy: CueTrackingPolicy = .accurate) -> Int {
        if let callbackGeneration, callbackGeneration != generation { return confirmedReadPosition }
        guard confidence >= (policy == .accurate ? 0.30 : 0.16), !tokens.isEmpty else { return confirmedReadPosition }
        recentTranscript = transcript
        let allHeard = Self.words(transcript)
        let heard = Array(allHeard.suffix(18))
        guard !heard.isEmpty else { return confirmedReadPosition }
        let low = max(0, confirmedReadPosition - 2)
        let searchAhead = policy == .accurate ? 42 : 72
        let high = min(tokens.count, confirmedReadPosition + searchAhead)
        var bestEnd = confirmedReadPosition
        var bestScore = 0
        var bestMatchScore = 0.0

        if policy == .accurate {
            // Preserve conservative exact contiguous matching for Word Tracking.
            for start in low..<high {
                for heardStart in allHeard.indices {
                    var matched = 0
                    while heardStart + matched < allHeard.count, start + matched < tokens.count,
                          tokens[start + matched].text == allHeard[heardStart + matched] { matched += 1 }
                    let end = start + matched
                    if matched > bestScore || (matched == bestScore && matched > 0 && abs(end - confirmedReadPosition) < abs(bestEnd - confirmedReadPosition)) {
                        bestScore = matched
                        bestEnd = end
                    }
                }
            }
            bestMatchScore = bestScore > 0 ? 1 : 0
        } else {
            // Bounded local sequence alignment tolerates small substitutions and omitted/inserted words.
            for start in low..<high {
                for heardStart in heard.indices {
                    let phrase = Array(heard[heardStart...])
                    let minimumLength = max(1, phrase.count - 2)
                    let maximumLength = min(phrase.count + 2, tokens.count - start, 18)
                    guard minimumLength <= maximumLength else { continue }
                    for length in minimumLength...maximumLength {
                        let scriptSlice = tokens[start..<(start + length)].map(\.text)
                        let score = Self.sequenceMatch(scriptSlice, phrase)
                        let exact = zip(scriptSlice, phrase).filter { $0.0 == $0.1 }.count
                        let end = start + length
                        if score > bestMatchScore ||
                            (score == bestMatchScore && score > 0 &&
                             (exact > bestScore || (exact == bestScore && abs(end - confirmedReadPosition) < abs(bestEnd - confirmedReadPosition)))) {
                            bestMatchScore = score
                            bestScore = exact
                            bestEnd = end
                        }
                    }
                }
            }
        }
        guard bestScore > 0,
              bestMatchScore >= (policy == .accurate ? 1 : 0.44),
              policy == .accurate || bestScore >= 1 else { return confirmedReadPosition }
        let target = max(confirmedReadPosition, bestEnd)
        let jump = target - confirmedReadPosition
        if heard.count == 1 {
            let weakTokens: Set<String> = ["a", "an", "the", "is", "and", "to", "my", "it", "of", "in", "on", "for"]
            let maximumLocalAdvance = weakTokens.contains(heard[0]) ? 3 : 4
            guard jump <= maximumLocalAdvance else { return confirmedReadPosition }
        }
        let confirmationThreshold = policy == .accurate ? 8 : 12
        let mediumThreshold = 5
        if jump > confirmationThreshold || (policy == .responsive && jump > mediumThreshold && bestMatchScore < 0.76) {
            let evidenceKey = Self.words(transcript).suffix(18).joined(separator: " ")
            if let pendingLargeJumpPosition, abs(pendingLargeJumpPosition - target) <= 3,
               !evidenceKey.isEmpty, evidenceKey != pendingLargeJumpEvidence {
                pendingLargeJumpConfirmations += 1
                self.pendingLargeJumpPosition = target
                pendingLargeJumpEvidence = evidenceKey
            }
            else if pendingLargeJumpPosition == nil || evidenceKey != pendingLargeJumpEvidence {
                pendingLargeJumpPosition = target
                pendingLargeJumpConfirmations = 1
                pendingLargeJumpEvidence = evidenceKey
            }
            guard pendingLargeJumpConfirmations >= (policy == .accurate || jump > 12 ? 2 : 1) else { return confirmedReadPosition }
        }
        pendingLargeJumpPosition = nil
        pendingLargeJumpConfirmations = 0
        pendingLargeJumpEvidence = ""
        confirmedReadPosition = target
        return target
    }

    @discardableResult
    public mutating func jump(to tokenIndex: Int) -> Int {
        confirmedReadPosition = min(tokens.count, max(0, tokenIndex))
        generation &+= 1
        pendingLargeJumpPosition = nil
        pendingLargeJumpConfirmations = 0
        pendingLargeJumpEvidence = ""
        recentTranscript = ""
        return confirmedReadPosition
    }

    public var isFinished: Bool { !tokens.isEmpty && confirmedReadPosition >= tokens.count }

    public var recentSpokenWords: String {
        Self.words(recentTranscript).suffix(7).joined(separator: " ")
    }

    public var upcomingContextWords: [String] {
        var seen = Set<String>()
        return tokens.dropFirst(confirmedReadPosition).prefix(80).map(\.text).filter { word in
            guard word.count >= 5, seen.insert(word).inserted else { return false }
            return true
        }.prefix(32).map { $0 }
    }

    public static func normalize(_ text: String) -> String {
        let value = text.lowercased().replacingOccurrences(of: "’", with: "'")
        return numberWord(value) ?? value
    }

    public static func words(_ text: String) -> [String] {
        let ns = text as NSString
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)?")
        let fillers: Set<String> = ["um", "uh", "erm", "er"]
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { normalize(ns.substring(with: $0.range)) }
            .filter { !fillers.contains($0) }
    }

    private static func numberWord(_ value: String) -> String? {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                     "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
        if let number = Int(value), (0...20).contains(number) { return words[number] }
        if let index = words.firstIndex(of: value) { return words[index] }
        return nil
    }

    private static func sequenceMatch(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var previous = Array(0...rhs.count).map(Double.init)
        for (row, left) in lhs.enumerated() {
            var current = [Double](repeating: 0, count: rhs.count + 1)
            current[0] = Double(row + 1)
            for column in 1...rhs.count {
                let a = left, b = rhs[column - 1]
                let substitution: Double
                if a == b { substitution = 0 }
                else if a.count > 2 && b.count > 2 && (a.hasPrefix(b) || b.hasPrefix(a)) { substitution = 0.55 }
                else if a.count > 3 && b.count > 3 && Self.editDistanceAtMostOne(a, b) { substitution = 0.7 }
                else { substitution = 1 }
                current[column] = min(previous[column] + 1, current[column - 1] + 0.85, previous[column - 1] + substitution)
            }
            previous = current
        }
        // Partial transcripts are often a prefix of the script window. Permit a short
        // unmatched tail in the script while requiring a good fit for the heard words.
        let distance = previous[rhs.count]
        return max(0, 1 - distance / Double(max(lhs.count, rhs.count)))
    }

    private static func editDistanceAtMostOne(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 }
            else if b.count > a.count { j += 1 }
            else { i += 1; j += 1 }
        }
        return edits + ((i < a.count || j < b.count) ? 1 : 0) <= 1
    }
}

public struct CueWaveformState: Sendable, Equatable {
    public let capacity: Int
    public let smoothing: Float
    public let minimumInterval: TimeInterval
    public private(set) var levels: [Float]
    public private(set) var displayedLevel: Float = 0
    public private(set) var isSpeaking = false
    private var lastUpdate: TimeInterval?

    public init(capacity: Int = 40, smoothing: Float = 0.62, minimumInterval: TimeInterval = 1.0 / 25) {
        self.capacity = max(1, capacity)
        self.smoothing = min(0.95, max(0, smoothing))
        self.minimumInterval = max(0, minimumInterval)
        self.levels = Array(repeating: 0.035, count: max(1, capacity))
    }

    /// Returns true only when a throttled sample is appended and the UI should redraw.
    @discardableResult
    public mutating func append(power: Float, at time: TimeInterval) -> Bool {
        guard time.isFinite else { return false }
        let safePower: Float = power.isFinite ? max(0, power) : 0
        if let lastUpdate, time - lastUpdate < minimumInterval { return false }
        lastUpdate = time
        let normalized = min(1, safePower * 8)
        displayedLevel = min(1, max(0, displayedLevel * smoothing + normalized * (1 - smoothing)))
        isSpeaking = displayedLevel >= 0.08
        levels.append(max(0.035, displayedLevel))
        if levels.count > capacity { levels.removeFirst(levels.count - capacity) }
        return true
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
    public private(set) var waveform = CueWaveformState()
    public init() {}

    public mutating func update(power: Float, threshold: Float = 0.035) -> Bool {
        _ = waveform.append(power: power, at: ProcessInfo.processInfo.systemUptime)
        isSpeaking = power.isFinite && power >= threshold
        return isSpeaking
    }
}
