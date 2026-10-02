import Foundation
import KioCore

public enum SemanticAction: String, Codable, Sendable { case convert, download }
public enum SemanticDomain: String, Codable, Sendable { case image, audio, video, table, remoteMedia }
public enum SemanticFormat: String, Codable, CaseIterable, Sendable {
    case png, jpeg, jpg, heic, heif, tiff, tif, webp
    case mp3, m4a, wav, flac
    case mp4, webm, mkv, mov
    case csv, json, xlsx
}

/// A small, typed representation of parameterized user intent. Paths and executable
/// arguments are deliberately absent; only the local capability compiler can create steps.
public struct SemanticIntent: Codable, Sendable, Equatable {
    public let action: SemanticAction
    public let domain: SemanticDomain
    public let sourceFormat: SemanticFormat?
    public let targetFormat: SemanticFormat
    public let preferredExtension: String
    public let quality: String?
    public let targetSizeBytes: Int64?
    public let negated: Bool

    public init(action: SemanticAction, domain: SemanticDomain, sourceFormat: SemanticFormat?,
                targetFormat: SemanticFormat, preferredExtension: String, quality: String? = nil,
                targetSizeBytes: Int64? = nil, negated: Bool = false) {
        self.action = action
        self.domain = domain
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        self.preferredExtension = preferredExtension
        self.quality = quality
        self.targetSizeBytes = targetSizeBytes
        self.negated = negated
    }
}

public enum SemanticIntentParseResult: Sendable, Equatable {
    case resolved(SemanticIntent, confidence: Double)
    case clarify(String)
    case noMatch
}

public struct SemanticTimeRange: Codable, Sendable, Equatable {
    public let startMilliseconds: Int64
    public let durationMilliseconds: Int64

    public init(startMilliseconds: Int64, durationMilliseconds: Int64) {
        self.startMilliseconds = startMilliseconds
        self.durationMilliseconds = durationMilliseconds
    }
}

/// Shared, bounded entity readers for page selections, durations, size targets and
/// rename destinations. They return typed values and nil when wording is ambiguous.
public enum SemanticValueParser {
    private static let numberWords = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19, "twenty": 20]

    public static func pageSelection(in request: String) -> [Int]? {
        let words = numberWords.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        if let first = captures(#"(?i)\bfirst\s+(\d+|"# + words + #")\s+pages?\b"#, in: request)?.first,
           let count = integer(first), (1...200).contains(count) { return Array(1...count) }
        let pattern = #"(?i)\bpages?\s+((?:\d+|"# + words + #")(?:\s*(?:,|and|through|to|[-–])\s*(?:\d+|"# + words + #"))*)\b"#
        guard let selection = captures(pattern, in: request)?.first else { return nil }
        let values = tokens(#"\d+|[a-z]+"#, in: selection).compactMap(integer)
        guard !values.isEmpty, values.allSatisfy({ (1...100_000).contains($0) }) else { return nil }
        if values.count == 2, selection.range(of: #"(?i)\b(?:through|to)\b|[-–]"#, options: .regularExpression) != nil {
            let (first, last) = (values[0], values[1])
            guard last >= first, last - first < 200 else { return nil }
            return Array(first...last)
        }
        guard values.count <= 200 else { return nil }
        return Array(Set(values)).sorted()
    }

    public static func videoTime(in request: String) -> Int64? {
        let pattern = #"(?i)\b(?:at|around)\s+((?:\d{1,2}:)?\d{1,2}:\d{2}|\d+(?:\.\d+)?)\s*(s|sec|seconds?|m|min|minutes?)?\b"#
        guard let value = captures(pattern, in: request)?.first, let seconds = timeSeconds([value, ""], defaultUnit: "s"),
              (0...86_400).contains(seconds) else { return nil }
        return Int64((seconds * 1_000).rounded())
    }

    public static func videoRange(in request: String) -> SemanticTimeRange? {
        let rangePattern = #"(?i)\bfrom\s+((?:\d{1,2}:)?\d{1,2}:\d{2}|\d+(?:\.\d+)?)\s*(s|sec|seconds?|m|min|minutes?)?\s+to\s+((?:\d{1,2}:)?\d{1,2}:\d{2}|\d+(?:\.\d+)?)\s*(s|sec|seconds?|m|min|minutes?)?\b"#
        if let values = captures(rangePattern, in: request), values.count == 4,
           let start = timeSeconds([values[0], values[1]], defaultUnit: "s"),
           let end = timeSeconds([values[2], values[3]], defaultUnit: "s"),
           start >= 0, end > start, end <= 86_400 {
            return SemanticTimeRange(startMilliseconds: Int64((start * 1_000).rounded()),
                                     durationMilliseconds: Int64(((end - start) * 1_000).rounded()))
        }
        let numeric = #"(?:\d+(?:\.\d+)?|"# + numberWords.keys.sorted { $0.count > $1.count }.joined(separator: "|") + #")"#
        let firstPattern = #"(?i)\bfirst\s+("# + numeric + #")\s*(seconds?|secs?|s|minutes?|mins?|m)\b"#
        if let values = captures(firstPattern, in: request), values.count == 2,
           let duration = timeSeconds(values, defaultUnit: "s"), duration > 0, duration <= 86_400 {
            return SemanticTimeRange(startMilliseconds: 0, durationMilliseconds: Int64((duration * 1_000).rounded()))
        }
        let startPattern = #"(?i)\bstart(?:ing)?\s+(?:at\s+)?("# + numeric + #")\s*(seconds?|secs?|s|minutes?|mins?|m)\s+for\s+("# + numeric + #")\s*(seconds?|secs?|s|minutes?|mins?|m)\b"#
        if let values = captures(startPattern, in: request), values.count == 4,
           let start = timeSeconds([values[0], values[1]], defaultUnit: "s"),
           let duration = timeSeconds([values[2], values[3]], defaultUnit: "s"),
           start >= 0, duration > 0, start + duration <= 86_400 {
            return SemanticTimeRange(startMilliseconds: Int64((start * 1_000).rounded()),
                                     durationMilliseconds: Int64((duration * 1_000).rounded()))
        }
        return nil
    }

    public static func renameTarget(in request: String) -> String? {
        let patterns = [
            #"(?i)\b(?:rename\s+(?:this|it|that)?\s*(?:to|as)?|call\s+(?:this|it|that)|name\s+(?:this|it|that)\s*(?:to|as)?)\s+[\"'“”‘’]?(.+?)[\"'“”‘’]?\s*[.!?]*$"#,
            #"(?i)\brename\b.+?\b(?:to|as)\s+[\"'“”‘’]?(.+?)[\"'“”‘’]?\s*[.!?]*$"#
        ]
        guard let value = patterns.lazy.compactMap({ captures($0, in: request)?.first }).first else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’.!?")))
        guard !name.isEmpty, name.count <= 100, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return name
    }

    public static func targetSizeBytes(in request: String) -> Int64? {
        let pattern = #"(?i)\b(?:under|below|less than|no more than|at most|around)\s+(\d+(?:\.\d+)?)\s*(kb|k|kilobytes?|mb|m|meg(?:abytes?)?|megs?|gb|g|gigabytes?)\b"#
        guard let values = captures(pattern, in: request), values.count == 2,
              let amount = Double(values[0]), amount > 0 else { return nil }
        let unit = values[1].lowercased()
        let multiplier: Double = unit.hasPrefix("g") ? 1_000_000_000 : (unit.hasPrefix("m") ? 1_000_000 : 1_000)
        let bytes = amount * multiplier
        return bytes.isFinite && bytes <= 100_000_000_000 ? Int64(bytes.rounded(.down)) : nil
    }

    private static func integer(_ text: String) -> Int? { Int(text) ?? numberWords[text.lowercased()] }

    private static func tokens(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { source.substring(with: $0.range).lowercased() }
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let source = text as NSString
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
    }

    private static func timeSeconds(_ values: [String], defaultUnit: String) -> Double? {
        guard let raw = values.first else { return nil }
        if raw.contains(":") {
            let parts = raw.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 || parts.count == 3 else { return nil }
            if parts.count == 2 { return parts[0] * 60 + parts[1] }
            return parts[0] * 3_600 + parts[1] * 60 + parts[2]
        }
        guard let amount = Double(raw) ?? numberWords[raw.lowercased()].map(Double.init), amount.isFinite else { return nil }
        let unit = (values.count > 1 && !values[1].isEmpty ? values[1] : defaultUnit).lowercased()
        return unit.hasPrefix("m") ? amount * 60 : amount
    }
}

/// Parses common destination-format relationships (including negation) rather than
/// selecting the first supported format token in a bag of words.
public enum SemanticIntentParser {
    private static let formatPattern = #"(?:png|jpe?g|heic|heif|tiff?|webp|mp3|m4a|wav|flac|mp4|webm|mkv|mov|csv|json|xlsx)"#

    /// Explicit negation is a hard stop: a language model must not reinterpret it
    /// into the operation the user said not to perform.
    public static func explicitlyNegatesTransformation(_ request: String) -> Bool {
        request.lowercased().range(
            of: #"\b(?:don't|do not|never|must not|not)\s+(?:ever\s+)?(?:convert|turn|make|export|save|change|download|get|acquire)\b"#,
            options: .regularExpression
        ) != nil
    }

    public static func parse(_ request: String) -> SemanticIntentParseResult {
        let hasArrowRelationship = request.contains("→") || request.contains("->")
        let normalized = request.lowercased()
            .replacingOccurrences(of: "→", with: " to ")
            .replacingOccurrences(of: "->", with: " to ")
        let hasExplicitAction = normalized.range(of: #"\b(?:convert|turn|make|export|save|give|change|download|get|acquire|need|want|extract|transcode)\b"#, options: .regularExpression) != nil
        let bareRequestedFormat = normalized.range(of: #"(?i)^\s*\.?"# + formatPattern + #"\s*,?\s*(?:please)?\s*[.!?]*$"#, options: .regularExpression) != nil
        guard hasArrowRelationship || hasExplicitAction || bareRequestedFormat else {
            return .noMatch
        }
        if explicitlyNegatesTransformation(normalized) {
            return .clarify("You said not to convert the file. Should Kio leave it unchanged, or convert it to a specific format?")
        }

        let patterns = [
            #"\b(?:from\s+)?\.?("# + formatPattern + #")\s+(?:to|into)\s+\.?("# + formatPattern + #")\b"#,
            #"\b(?:to|into|as)\s+(?:(?:a|an)\s+)?\.?("# + formatPattern + #")\b"#,
            #"\bmake\s+(?:this|it|that)?\s*(?:a|an)?\s*\.?("# + formatPattern + #")\b"#,
            #"\bgive\s+me\s+(?:a|an)?\s*\.?("# + formatPattern + #")\s+(?:version|copy)\b"#,
            #"\.?("# + formatPattern + #")\s*,?\s*(?:please)?\s*[.!?]*$"#
        ]
        var source: SemanticFormat?
        var target: SemanticFormat?
        for (index, pattern) in patterns.enumerated() {
            guard let match = captures(pattern, in: normalized) else { continue }
            if index == 0, match.count == 2 {
                source = SemanticFormat(rawValue: match[0])
                target = SemanticFormat(rawValue: match[1])
            } else if let value = match.last {
                target = SemanticFormat(rawValue: value)
            }
            if target != nil { break }
        }
        guard let target else { return .noMatch }
        let preferred = target.rawValue
        let action: SemanticAction = normalized.range(of: #"\b(?:download|get|acquire)\b"#, options: .regularExpression) != nil ? .download : .convert
        let domain: SemanticDomain
        switch target {
        case .png, .jpeg, .jpg, .heic, .heif, .tiff, .tif, .webp: domain = .image
        case .mp3, .m4a, .wav, .flac: domain = .audio
        case .mp4, .webm, .mkv, .mov: domain = .video
        case .csv, .json, .xlsx: domain = .table
        }
        let resolvedDomain: SemanticDomain = action == .download ? .remoteMedia : domain
        return .resolved(SemanticIntent(action: action, domain: resolvedDomain, sourceFormat: source,
                                         targetFormat: target, preferredExtension: preferred,
                                         quality: quality(in: normalized), targetSizeBytes: sizeLimit(in: normalized)), confidence: 0.98)
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let ns = text as NSString
        return (1..<match.numberOfRanges).compactMap { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return nil }
            return ns.substring(with: range)
        }
    }

    private static func quality(in text: String) -> String? {
        if text.range(of: #"\b(?:best|highest quality)\b"#, options: .regularExpression) != nil { return "best" }
        for height in [2160, 1440, 1080, 720, 480, 360] where text.contains("\(height)p") { return "\(height)p" }
        return nil
    }

    private static func sizeLimit(in text: String) -> Int64? {
        guard let values = captures(#"\b(?:under|below|less than|no more than|around|at most)\s+(\d+(?:\.\d+)?)\s*(kb|k|kilobytes?|mb|m|megabytes?|gb|g|gigabytes?|megs?)\b"#, in: text),
              values.count == 2, let amount = Double(values[0]), amount > 0 else { return nil }
        let unit = values[1]
        let multiplier: Double = unit.hasPrefix("g") ? 1_000_000_000 : (unit.hasPrefix("m") ? 1_000_000 : 1_000)
        let bytes = amount * multiplier
        return bytes <= 100_000_000_000 ? Int64(bytes) : nil
    }
}

public enum CapabilityCompiler {
    public static func compile(_ intent: SemanticIntent, request: String, artifacts: [ArtifactRef]) -> TaskPlan? {
        guard !intent.negated, !artifacts.isEmpty else { return nil }
        let ids = artifacts.map(\.id)
        let step: TaskStep?
        switch intent.domain {
        case .image:
            guard intent.targetSizeBytes == nil, matchesSourceFormat(intent.sourceFormat, artifacts: artifacts),
                  (1...32).contains(artifacts.count), artifacts.allSatisfy({ $0.kind == .image }) else { return nil }
            let format: String
            switch intent.targetFormat {
            case .png: format = "png"
            case .jpeg, .jpg: format = intent.preferredExtension
            case .heic, .heif: format = "heic"
            case .tiff, .tif: format = "tiff"
            case .webp: format = "webp"
            default: return nil
            }
            step = TaskStep(operation: artifacts.count == 1 ? .convertImage : .batchConvertImages,
                            source: .artifacts(ids), arguments: .imageConvert(format: format))
        case .audio:
            guard intent.targetSizeBytes == nil, artifacts.count == 1,
                  matchesSourceFormat(intent.sourceFormat, artifacts: artifacts),
                  let format = AudioTargetFormat(rawValue: intent.targetFormat.rawValue) else { return nil }
            if artifacts[0].kind == .url {
                step = TaskStep(operation: .downloadRemoteAudio, source: .artifacts(ids),
                                arguments: .remoteMedia(quality: intent.quality, format: format.rawValue))
            } else {
                guard [.audio, .video].contains(artifacts[0].kind) else { return nil }
                step = TaskStep(operation: .convertAudio, source: .artifacts(ids), arguments: .audioConvert(format: format))
            }
        case .video:
            guard intent.targetSizeBytes == nil,
                  artifacts.count == 1, artifacts[0].kind == .video,
                  matchesSourceFormat(intent.sourceFormat, artifacts: artifacts), intent.targetFormat == .mp4 else { return nil }
            step = TaskStep(operation: .transcodeVideo, source: .artifacts(ids))
        case .table:
            guard intent.targetSizeBytes == nil, artifacts.count == 1,
                  matchesSourceFormat(intent.sourceFormat, artifacts: artifacts) else { return nil }
            let ext = artifacts[0].fileURL.pathExtension.lowercased()
            if intent.targetFormat == .csv, ext == "xlsx" {
                step = TaskStep(operation: .importXLSX, source: .artifacts(ids))
            } else if intent.targetFormat == .csv, ext == "json" {
                step = TaskStep(operation: .jsonToCSV, source: .artifacts(ids))
            } else if intent.targetFormat == .json, ["csv", "tsv"].contains(ext) {
                step = TaskStep(operation: .csvToJSON, source: .artifacts(ids))
            } else { return nil }
        case .remoteMedia:
            guard intent.targetSizeBytes == nil, artifacts.count == 1, artifacts[0].kind == .url else { return nil }
            if let audio = AudioTargetFormat(rawValue: intent.targetFormat.rawValue) {
                step = TaskStep(operation: .downloadRemoteAudio, source: .artifacts(ids),
                                arguments: .remoteMedia(quality: intent.quality, format: audio.rawValue))
            } else {
                let videoFormat: String
                switch intent.targetFormat { case .mp4, .webm, .mkv, .mov: videoFormat = intent.targetFormat.rawValue; default: return nil }
                step = TaskStep(operation: .downloadRemoteVideo, source: .artifacts(ids),
                                arguments: .remoteMedia(quality: intent.quality, format: videoFormat))
            }
        }
        guard let step else { return nil }
        guard FastPathPlanner.isCompatible(step.operation, inputKinds: artifacts.map(\.kind)),
              FastPathPlanner.hasValidArguments(step.arguments, for: step.operation) else { return nil }
        return TaskPlan(request: request, steps: [step])
    }

    private static func matchesSourceFormat(_ source: SemanticFormat?, artifacts: [ArtifactRef]) -> Bool {
        guard let source else { return true }
        let expected: Set<String> = switch source {
        case .png: ["png"]
        case .jpeg: ["jpeg", "jpg"]
        case .jpg: ["jpg", "jpeg"]
        case .heic: ["heic", "heif"]
        case .heif: ["heif", "heic"]
        case .tiff: ["tiff", "tif"]
        case .tif: ["tif", "tiff"]
        case .webp: ["webp"]
        case .mp3, .m4a, .wav, .flac: [source.rawValue]
        case .mp4: ["mp4", "m4v"]
        case .webm, .mkv, .mov: [source.rawValue]
        case .csv: ["csv", "tsv"]
        case .json: ["json"]
        case .xlsx: ["xlsx"]
        }
        return artifacts.allSatisfy { expected.contains($0.fileURL.pathExtension.lowercased()) }
    }
}
