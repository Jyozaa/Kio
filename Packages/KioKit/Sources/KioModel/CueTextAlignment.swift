import Foundation

public struct CueToken: Sendable, Equatable {
    public let text: String
    public let surface: String
    public let range: NSRange
}

public enum CueTrackingPolicy: Sendable, Equatable {
    case accurate
    case responsive
}

public enum CueTranscriptEvidence: Sendable, Equatable {
    case measuredConfidence(Float)
    case volatile
    case final
}

/// Monotonic, anchored alignment for revised Speech partial transcripts.
/// Matching begins at the confirmed script position and never scans ahead for a later phrase.
public struct CueTextAlignment: Sendable, Equatable {
    public let tokens: [CueToken]
    public private(set) var confirmedReadPosition = 0
    public private(set) var generation = 0
    private var pendingLargeJumpPosition: Int?
    private var pendingLargeJumpEvidence: Set<String> = []
    private var recentTranscript = ""

    private static let maximumMatchWords = 18
    private static let maximumSourceSkips = 3
    private static let priorContextWords = 1
    private static let fillers: Set<String> = ["um", "uh", "erm", "er"]
    private static let commonFuzzyWords: Set<String> = [
        "a", "about", "after", "again", "also", "among", "an", "and", "another", "any", "are", "around", "as", "at", "be", "because", "before", "being", "between", "but", "by", "could", "did", "do", "does", "doing", "during", "every", "first", "for", "found", "from", "get", "getting", "going", "go", "great", "have", "he", "her", "here", "him", "his", "how", "i", "if", "in", "into", "is", "it", "its", "just", "large", "little", "maybe", "me", "might", "more", "most", "my", "never", "no", "not", "of", "on", "one", "or", "other", "our", "people", "place", "really", "right", "same", "she", "should", "since", "small", "so", "some", "something", "still", "the", "their", "them", "then", "there", "these", "they", "thing", "think", "this", "those", "through", "to", "today", "under", "until", "us", "using", "very", "was", "we", "were", "what", "when", "where", "which", "while", "will", "with", "would", "you", "your"
    ]

    private struct MappedToken {
        let text: String
        let sourceIndex: Int
        let completesSourceToken: Bool
    }
    private struct Candidate {
        let target: Int
        let score: Double
        let matchedWords: Int
        let containsAlias: Bool
    }
    private struct AlignmentCell {
        var cost: Double
        var exact: Int
        var fuzzy: Int
        var aliases: Int
        var operation: UInt8 // 1: pair, 2: omit script token, 3: skip spoken token
    }
    private struct AlignmentMetrics {
        let score: Double
        let exact: Int
        let fuzzy: Int
        let aliases: Int
        let lastSourceMatched: Bool
        var matchedWords: Int { exact + fuzzy + aliases }
    }

    public init(script: String, generation: Int = 0) {
        self.generation = max(0, generation)
        let ns = script as NSString
        let pattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)?")
        tokens = pattern.matches(in: script, range: NSRange(location: 0, length: ns.length)).map { match in
            let surface = ns.substring(with: match.range)
            return CueToken(text: Self.normalize(surface), surface: surface, range: match.range)
        }
    }

    @discardableResult
    public mutating func consume(_ transcript: String, evidence: CueTranscriptEvidence,
                                 generation callbackGeneration: Int? = nil,
                                 policy: CueTrackingPolicy = .accurate) -> Int {
        let confidence: Float
        switch evidence {
        case .measuredConfidence(let value): confidence = value
        case .volatile: confidence = 0.42
        case .final: confidence = 0.72
        }
        return consume(transcript, confidence: confidence, generation: callbackGeneration, policy: policy)
    }

    @discardableResult
    public mutating func consume(_ transcript: String, confidence: Float, generation callbackGeneration: Int? = nil,
                                 policy: CueTrackingPolicy = .accurate) -> Int {
        if let callbackGeneration, callbackGeneration != generation { return confirmedReadPosition }
        guard confidence.isFinite, confidence >= (policy == .accurate ? 0.30 : 0.16), !tokens.isEmpty else {
            return confirmedReadPosition
        }
        recentTranscript = transcript
        let heard = Self.contextualAlternatives(Self.words(transcript))
        guard !heard.isEmpty else { return confirmedReadPosition }

        let character = characterCandidate(transcript)
        let word = wordCandidate(heard, policy: policy)
        guard let candidate = [character, word].compactMap({ $0 }).max(by: Self.candidatePrecedes) else {
            return confirmedReadPosition
        }
        let target = max(confirmedReadPosition, min(tokens.count, candidate.target))
        let jump = target - confirmedReadPosition
        guard jump > 0 else { return confirmedReadPosition }

        let confirmationThreshold = policy == .accurate ? 8 : 12
        if jump > confirmationThreshold {
            let identity = Self.words(transcript).suffix(Self.maximumMatchWords).joined(separator: " ")
            guard !identity.isEmpty else { return confirmedReadPosition }
            if let pendingLargeJumpPosition, abs(pendingLargeJumpPosition - target) <= 2 {
                // Identical recognizer callbacks do not constitute another confirmation.
                guard !pendingLargeJumpEvidence.contains(identity) else { return confirmedReadPosition }
                pendingLargeJumpEvidence.insert(identity)
                self.pendingLargeJumpPosition = target
            } else {
                pendingLargeJumpPosition = target
                pendingLargeJumpEvidence = [identity]
            }
            guard pendingLargeJumpEvidence.count >= 2 else { return confirmedReadPosition }
        }
        pendingLargeJumpPosition = nil
        pendingLargeJumpEvidence.removeAll(keepingCapacity: true)
        confirmedReadPosition = target
        return target
    }

    @discardableResult
    public mutating func jump(to tokenIndex: Int) -> Int {
        confirmedReadPosition = min(tokens.count, max(0, tokenIndex))
        generation &+= 1
        pendingLargeJumpPosition = nil
        pendingLargeJumpEvidence.removeAll(keepingCapacity: true)
        recentTranscript = ""
        return confirmedReadPosition
    }

    public var isFinished: Bool { !tokens.isEmpty && confirmedReadPosition >= tokens.count }

    public var recentSpokenWords: String {
        Self.words(recentTranscript).suffix(7).joined(separator: " ")
    }

    public var upcomingContextWords: [String] {
        CueContextVocabulary.terms(in: tokens, from: confirmedReadPosition)
    }

    public static func normalize(_ text: String) -> String {
        let value = text.lowercased().replacingOccurrences(of: "’", with: "'")
        return numberWord(value) ?? value
    }

    public static func words(_ text: String) -> [String] {
        rawWords(text).map(normalize).filter { !fillers.contains($0) }
    }

    private static func rawWords(_ text: String) -> [String] {
        let ns = text as NSString
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’][\\p{L}\\p{N}]+)?")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { ns.substring(with: $0.range).lowercased().replacingOccurrences(of: "’", with: "'") }
            .filter { !fillers.contains($0) }
    }

    private func characterCandidate(_ transcript: String) -> Candidate? {
        let start = alignmentStart(for: Self.contextualAlternatives(Self.words(transcript)))
        let sourceTokens = Array(tokens.dropFirst(start).prefix(Self.maximumMatchWords))
        guard !sourceTokens.isEmpty else { return nil }
        var sourceCharacters: [(Character, Int, Bool)] = []
        for (offset, token) in sourceTokens.enumerated() {
            let wordCharacters = token.surface.lowercased().filter { $0.isLetter || $0.isNumber }
            for (index, character) in wordCharacters.enumerated() {
                sourceCharacters.append((character, start + offset, index == wordCharacters.count - 1))
            }
        }
        let spokenWords = Array(Self.rawWords(transcript).suffix(Self.maximumMatchWords))
        guard !sourceCharacters.isEmpty, !spokenWords.isEmpty else { return nil }
        var best: Candidate?
        for wordStart in spokenWords.indices {
            let spokenSequence = Array(spokenWords[wordStart...])
            if wordStart > 0 && spokenSequence.count == 1
                && !priorTranscriptPrefixMatches(spokenWords, count: wordStart, before: start) { continue }
            let spokenCharacters = Array(spokenSequence.joined())
            var spokenBoundaries = Set<Int>()
            var boundary = 0
            for word in spokenSequence {
                boundary += word.count
                spokenBoundaries.insert(boundary)
            }
            guard !spokenCharacters.isEmpty else { continue }
            var matchedCharacters = 0
            while matchedCharacters < min(sourceCharacters.count, spokenCharacters.count),
                  sourceCharacters[matchedCharacters].0 == spokenCharacters[matchedCharacters] {
                matchedCharacters += 1
            }
            if matchedCharacters < spokenCharacters.count, spokenBoundaries.contains(matchedCharacters) { continue }
            guard matchedCharacters > 0 else { continue }
            let completed = sourceCharacters.prefix(matchedCharacters).enumerated()
                .compactMap { offset, value in
                    value.2 && (spokenBoundaries.contains(offset + 1) || offset + 1 == spokenCharacters.count)
                        ? value.1 + 1 : nil
                }.max() ?? start
            guard completed > start else { continue }
            let score = Double(matchedCharacters) / Double(max(matchedCharacters, spokenCharacters.count))
            let candidate = Candidate(target: completed, score: score,
                                      matchedWords: completed - start, containsAlias: false)
            if best.map({ Self.candidatePrecedes($0, candidate) }) ?? true { best = candidate }
        }
        return best
    }

    private func wordCandidate(_ heardCandidates: [[String]], policy: CueTrackingPolicy) -> Candidate? {
        let start = alignmentStart(for: heardCandidates)
        let window = Array(tokens.enumerated().dropFirst(start).prefix(Self.maximumMatchWords))
        guard !window.isEmpty else { return nil }
        let sourceForms = mappedSourceForms(window)
        var best: Candidate?
        let minimumScore = policy == .accurate ? 0.66 : 0.50

        for source in sourceForms {
            let sourceCount = min(source.count, Self.maximumMatchWords + 8)
            guard sourceCount > 0 else { continue }
            for spoken in heardCandidates {
                guard !spoken.isEmpty else { continue }
                for spokenStart in spoken.indices {
                    let phrase = Array(spoken[spokenStart...].prefix(Self.maximumMatchWords))
                    let minimumLength = max(1, phrase.count - Self.maximumSourceSkips)
                    let maximumLength = min(sourceCount, phrase.count + Self.maximumSourceSkips)
                    guard minimumLength <= maximumLength else { continue }
                    for length in minimumLength...maximumLength {
                        let scriptPrefix = Array(source.prefix(length))
                        let metrics = Self.alignmentMetrics(scriptPrefix.map(\.text), phrase)
                        let exactLocalSingle = metrics.matchedWords == 1
                            && (spoken.count == 1 || priorTranscriptPrefixMatches(spoken, count: spokenStart, before: start))
                            && length <= Self.maximumSourceSkips + 1
                            && (metrics.exact == 1 || metrics.aliases == 1)
                        guard (metrics.score >= minimumScore || exactLocalSingle), metrics.lastSourceMatched,
                              metrics.matchedWords > 0 else { continue }
                        if metrics.matchedWords == 1 {
                            guard exactLocalSingle else { continue }
                        }
                        let target = scriptPrefix.compactMap {
                            $0.completesSourceToken ? $0.sourceIndex + 1 : nil
                        }.max() ?? start
                        guard target > start else { continue }
                        let candidate = Candidate(target: target, score: metrics.score,
                                                  matchedWords: metrics.matchedWords,
                                                  containsAlias: metrics.aliases > 0)
                        if best.map({ Self.candidatePrecedes($0, candidate) }) ?? true { best = candidate }
                    }
                }
            }
        }
        return best
    }

    private func alignmentStart(for heardCandidates: [[String]]) -> Int {
        guard Self.priorContextWords > 0, confirmedReadPosition > 0,
              tokens.indices.contains(confirmedReadPosition - 1) else { return confirmedReadPosition }
        let previous = tokens[confirmedReadPosition - 1].text
        let overlapsPrevious = heardCandidates.contains { candidate in
            guard let first = candidate.first else { return false }
            return Self.wordMatch(previous, first).cost < 1
        }
        return overlapsPrevious ? confirmedReadPosition - 1 : confirmedReadPosition
    }

    private func priorTranscriptPrefixMatches(_ heard: [String], count: Int, before anchor: Int) -> Bool {
        guard count > 0, count <= anchor, tokens.indices.contains(anchor - count) else { return false }
        for offset in 0..<count {
            let expected = tokens[anchor - count + offset].text
            guard Self.wordMatch(expected, heard[offset]).cost < 1 else { return false }
        }
        return true
    }

    private func mappedSourceForms(_ window: [(offset: Int, element: CueToken)]) -> [[MappedToken]] {
        var forms = [window.map { MappedToken(text: $0.element.text, sourceIndex: $0.offset, completesSourceToken: true) }]
        for item in window {
            let surface = item.element.surface
            guard surface.count >= 2, surface.count <= 6, surface.allSatisfy(\.isNumber),
                  let number = Int(surface), let digits = Self.spokenDigits(surface),
                  let cardinal = Self.cardinalWords(number) else { continue }
            for replacement in [digits, cardinal] where forms.count < 10 {
                let previous = forms
                for form in previous where forms.count < 10 {
                    guard let first = form.firstIndex(where: { $0.sourceIndex == item.offset }),
                          form.filter({ $0.sourceIndex == item.offset }).count == 1 else { continue }
                    var value = form
                    value.remove(at: first)
                    let mapped = replacement.enumerated().map { index, text in
                        MappedToken(text: text, sourceIndex: item.offset, completesSourceToken: index == replacement.count - 1)
                    }
                    value.insert(contentsOf: mapped, at: first)
                    if !forms.contains(where: { $0.map(\.text) == value.map(\.text) }) { forms.append(value) }
                }
            }
        }
        return forms
    }

    private static func alignmentMetrics(_ lhs: [String], _ rhs: [String]) -> AlignmentMetrics {
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return AlignmentMetrics(score: 0, exact: 0, fuzzy: 0, aliases: 0, lastSourceMatched: false)
        }
        var matrix = Array(repeating: Array(repeating: AlignmentCell(cost: 0, exact: 0, fuzzy: 0, aliases: 0, operation: 0), count: rhs.count + 1), count: lhs.count + 1)
        for row in 1...lhs.count {
            matrix[row][0] = AlignmentCell(cost: Double(row), exact: 0, fuzzy: 0, aliases: 0, operation: 2)
        }
        for column in 1...rhs.count {
            matrix[0][column] = AlignmentCell(cost: Double(column), exact: 0, fuzzy: 0, aliases: 0, operation: 3)
        }
        for row in 1...lhs.count {
            for column in 1...rhs.count {
                let match = wordMatch(lhs[row - 1], rhs[column - 1])
                var diagonal = matrix[row - 1][column - 1]
                diagonal.cost += match.cost
                diagonal.exact += match.exact ? 1 : 0
                diagonal.fuzzy += match.fuzzy ? 1 : 0
                diagonal.aliases += match.alias ? 1 : 0
                diagonal.operation = 1
                var dropSource = matrix[row - 1][column]
                dropSource.cost += 1
                dropSource.operation = 2
                var skipSpoken = matrix[row][column - 1]
                skipSpoken.cost += 1
                skipSpoken.operation = 3
                matrix[row][column] = [diagonal, dropSource, skipSpoken].min(by: cellPrecedes)!
            }
        }
        let final = matrix[lhs.count][rhs.count]
        var row = lhs.count, column = rhs.count
        var lastSourceMatched = false
        while row > 0 || column > 0 {
            let operation = matrix[row][column].operation
            if operation == 1, row > 0, column > 0 {
                if row == lhs.count { lastSourceMatched = wordMatch(lhs[row - 1], rhs[column - 1]).cost < 1 }
                row -= 1
                column -= 1
            } else if operation == 2, row > 0 {
                row -= 1
            } else if operation == 3, column > 0 {
                column -= 1
            } else { break }
        }
        let score = max(0, 1 - final.cost / Double(max(lhs.count, rhs.count)))
        return AlignmentMetrics(score: score, exact: final.exact, fuzzy: final.fuzzy,
                                aliases: final.aliases, lastSourceMatched: lastSourceMatched)
    }

    private static func cellPrecedes(_ lhs: AlignmentCell, _ rhs: AlignmentCell) -> Bool {
        if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
        if lhs.exact + lhs.fuzzy + lhs.aliases != rhs.exact + rhs.fuzzy + rhs.aliases {
            return lhs.exact + lhs.fuzzy + lhs.aliases > rhs.exact + rhs.fuzzy + rhs.aliases
        }
        return lhs.operation < rhs.operation
    }

    private static func wordMatch(_ lhs: String, _ rhs: String) -> (cost: Double, exact: Bool, fuzzy: Bool, alias: Bool) {
        if lhs == rhs { return (0, true, false, false) }
        if lhs == "kio" && ["kyo", "keo"].contains(rhs) { return (0.18, false, false, true) }
        guard isDistinctive(lhs), isDistinctive(rhs) else { return (1, false, false, false) }
        if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) { return (0.30, false, true, false) }
        if editDistanceAtMostOne(lhs, rhs) { return (0.35, false, true, false) }
        return (1, false, false, false)
    }

    private static func candidatePrecedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if abs(lhs.score - rhs.score) > 0.000_001 { return lhs.score < rhs.score }
        if lhs.matchedWords != rhs.matchedWords { return lhs.matchedWords < rhs.matchedWords }
        if lhs.containsAlias != rhs.containsAlias { return !lhs.containsAlias }
        return lhs.target < rhs.target
    }

    private static func numberWord(_ value: String) -> String? {
        let values = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                      "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
        if let number = Int(value), (0...20).contains(number) { return values[number] }
        return values.contains(value) ? value : nil
    }

    private static func contextualAlternatives(_ words: [String]) -> [[String]] {
        let base = Array(words.suffix(maximumMatchWords))
        var results = [base]
        for index in base.indices where results.count < 10 {
            guard base[index].count >= 2, base[index].count <= 6,
                  base[index].allSatisfy(\.isNumber), let number = Int(base[index]),
                  let digits = spokenDigits(base[index]), let cardinal = cardinalWords(number) else { continue }
            for replacement in [digits, cardinal] where replacement != [base[index]] {
                var candidate = base
                candidate.replaceSubrange(index...index, with: replacement)
                if !results.contains(candidate) { results.append(candidate) }
                if results.count >= 10 { break }
            }
        }
        return results
    }

    private static func spokenDigits(_ value: String) -> [String]? {
        let names = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let result = value.compactMap { $0.wholeNumberValue }.map { names[$0] }
        return result.count == value.count ? result : nil
    }

    private static func cardinalWords(_ value: Int) -> [String]? {
        guard (0...999_999).contains(value) else { return nil }
        let small = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                     "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        func underThousand(_ number: Int) -> [String] {
            var result: [String] = []
            var remainder = number
            if remainder >= 100 { result += [small[remainder / 100], "hundred"]; remainder %= 100 }
            if remainder >= 20 { result.append(tens[remainder / 10]); remainder %= 10 }
            if remainder > 0 { result.append(small[remainder]) }
            return result
        }
        if value == 0 { return ["zero"] }
        var result: [String] = []
        if value >= 1_000 { result += underThousand(value / 1_000) + ["thousand"] }
        if value % 1_000 != 0 { result += underThousand(value % 1_000) }
        return result
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

    private static func isDistinctive(_ word: String) -> Bool {
        word.count >= 4 && word.allSatisfy(\.isLetter) && !commonFuzzyWords.contains(word)
    }
}

/// Bounded, script-relative recognition vocabulary. Only refresh after a meaningful
/// amount of confirmed reading progress, so changing context does not churn Speech.
public enum CueContextVocabulary {
    private static let commonWords: Set<String> = ["a", "an", "and", "are", "as", "at", "be", "but", "by", "do", "for", "from", "go", "has", "have", "he", "her", "here", "him", "his", "how", "i", "if", "in", "is", "it", "its", "me", "my", "no", "not", "of", "on", "or", "our", "she", "so", "the", "their", "them", "then", "there", "these", "they", "this", "to", "up", "us", "was", "we", "were", "what", "when", "who", "will", "with", "you", "your"]
    public static let refreshStride = 8

    public static func terms(in tokens: [CueToken], from position: Int, maximum: Int = 32) -> [String] {
        var seen = Set<String>()
        return tokens.dropFirst(min(tokens.count, max(0, position))).prefix(160).compactMap { token in
            let word = token.text
            let surface = token.surface
            let letters = surface.filter(\.isLetter)
            let acronym = letters.count >= 2 && letters.count <= 8 && letters.allSatisfy(\.isUppercase)
            let properName = surface.first.map(\.isUppercase) == true && !commonWords.contains(word)
            guard (word == "kio" || acronym || properName || word.count >= 5 || word.count >= 3),
                  !commonWords.contains(word), seen.insert(word).inserted else { return nil }
            return surface
        }.prefix(max(0, maximum)).map { $0 }
    }

    public static func shouldRefresh(from previousPosition: Int, to currentPosition: Int) -> Bool {
        guard currentPosition > previousPosition else { return false }
        return currentPosition / refreshStride > previousPosition / refreshStride
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
