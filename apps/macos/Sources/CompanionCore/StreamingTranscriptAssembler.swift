import Foundation

/// Reconstructs whisper-stream's terminal-style rolling hypotheses and its
/// periodic newline boundaries without treating every rewrite as a new segment.
public struct StreamingTranscriptAssembler: Sendable {
    private let maximumLength: Int
    private var committed = ""
    private var hypothesis = ""
    private var currentLine = ""
    private var escapeState = 0
    private var escapeSequence = ""

    public init(maximumLength: Int = 4000) {
        self.maximumLength = max(256, maximumLength)
    }

    public var transcript: String {
        Self.merge(committed, hypothesis, maximumLength: maximumLength)
    }

    /// Consume text decoded from whisper-stream stdout and return the assembled
    /// transcript. Incomplete lines and ANSI escape sequences remain buffered.
    @discardableResult
    public mutating func append(_ chunk: String) -> String {
        for scalar in chunk.unicodeScalars {
            if escapeState == 1 {
                if scalar == "[" {
                    escapeState = 2
                    escapeSequence = ""
                } else {
                    escapeState = 0
                }
                continue
            }
            if escapeState == 2 {
                let value = scalar.value
                if (0x40...0x7e).contains(value) {
                    if scalar == "K" {
                        updateHypothesis(from: currentLine)
                        currentLine = ""
                    }
                    escapeSequence = ""
                    escapeState = 0
                } else if escapeSequence.count < 16 {
                    escapeSequence.unicodeScalars.append(scalar)
                } else {
                    escapeSequence = ""
                    escapeState = 0
                }
                continue
            }

            if scalar.value == 0x1b {
                escapeState = 1
            } else if scalar == "\r" {
                updateHypothesis(from: currentLine)
                currentLine = ""
            } else if scalar == "\n" {
                finishLine()
            } else if scalar.value >= 0x20 && scalar.value != 0x7f {
                if currentLine.unicodeScalars.count < maximumLength {
                    currentLine.unicodeScalars.append(scalar)
                }
            }
        }
        updateHypothesis(from: currentLine)
        return transcript
    }

    /// Commit the last unterminated rolling line before the stream is stopped.
    @discardableResult
    public mutating func finish() -> String {
        updateHypothesis(from: currentLine)
        commitHypothesis()
        currentLine = ""
        escapeSequence = ""
        escapeState = 0
        return transcript
    }

    public mutating func reset() {
        committed = ""
        hypothesis = ""
        currentLine = ""
        escapeSequence = ""
        escapeState = 0
    }

    private mutating func finishLine() {
        let value = Self.clean(currentLine)
        if !value.isEmpty {
            if value == "[Start speaking]" || value == "[BLANK_AUDIO]" {
                currentLine = ""
                return
            }
            updateHypothesis(from: value)
            commitHypothesis()
        }
        currentLine = ""
    }

    private mutating func updateHypothesis(from line: String) {
        let value = Self.clean(line)
        guard !value.isEmpty,
              value != "[Start speaking]",
              value != "[BLANK_AUDIO]",
              !value.hasPrefix("### Transcription") else { return }
        hypothesis = Self.bounded(value, to: maximumLength)
    }

    private mutating func commitHypothesis() {
        guard !hypothesis.isEmpty else { return }
        committed = Self.merge(committed, hypothesis, maximumLength: maximumLength)
        hypothesis = ""
    }

    private static func clean(_ value: String) -> String {
        var text = value
            .replacingOccurrences(
                of: #"^\[\d{2}:\d{2}:\d{2}\.\d+\s*-->\s*[^\]]+\]\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s*\[BLANK_AUDIO\]\s*$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("### Transcription"), text.hasSuffix(" END") {
            text = ""
        }
        return text
    }

    private static func merge(_ prefix: String, _ next: String, maximumLength: Int) -> String {
        let left = prefix.split(whereSeparator: \.isWhitespace).map(String.init)
        let right = next.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !right.isEmpty else { return bounded(prefix, to: maximumLength) }
        guard !left.isEmpty else { return bounded(next, to: maximumLength) }

        let maximumOverlap = min(left.count, right.count)
        var overlap = 0
        if maximumOverlap > 0 {
            for count in stride(from: maximumOverlap, through: 1, by: -1) {
                let suffix = left.suffix(count)
                let head = right.prefix(count)
                if zip(suffix, head).allSatisfy({ normalizedToken($0.0) == normalizedToken($0.1) }) {
                    overlap = count
                    break
                }
            }
        }
        let merged = (left + right.dropFirst(overlap)).joined(separator: " ")
        return bounded(merged, to: maximumLength)
    }

    private static func normalizedToken(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters).casefolded
    }

    private static func bounded(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let suffix = String(text.suffix(limit))
        guard let space = suffix.firstIndex(of: " ") else { return suffix }
        return String(suffix[suffix.index(after: space)...])
    }
}

private extension String {
    var casefolded: String { folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
}
