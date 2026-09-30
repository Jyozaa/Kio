import Foundation
import KioCore

public struct PlanningContext: Sendable {
    public let activeOutput: ArtifactRef?
    public let previousOperation: ToolOperation?

    public init(activeOutput: ArtifactRef? = nil, previousOperation: ToolOperation? = nil) {
        self.activeOutput = activeOutput
        self.previousOperation = previousOperation
    }
}

/// Conservative, deterministic routing for a small set of unambiguous operations.
/// Unrecognized language is returned as a clarification; it never creates tool names.
public struct FastPathPlanner: Sendable {
    public init() {}

    public func plan(request: String, artifacts: [ArtifactRef], context: PlanningContext = .init()) -> TaskPlan {
        let words = Self.words(in: request)
        let inputs = artifacts.isEmpty ? context.activeOutput.map { [$0] } ?? [] : artifacts
        let ids = inputs.map(\.id)
        let sizeTarget = Self.byteLimit(in: request)

        if words.contains("merge"), inputs.filter({ $0.kind == .pdf }).count >= 2 {
            var steps = [TaskStep(operation: .mergePDFs, source: .artifacts(ids))]
            if let sizeTarget, let merge = steps.last {
                steps.append(TaskStep(operation: .compressPDF, source: .previousStep(merge.id), arguments: .pdfCompression(maxBytes: sizeTarget)))
            }
            return TaskPlan(request: request, steps: steps)
        }
        if words.contains("remove"), (words.contains("page") || words.contains("pages")), let pdf = inputs.first(where: { $0.kind == .pdf }),
           let range = Self.pageRange(in: request) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .removePDFPages, source: .artifacts([pdf.id]), arguments: .removePages(indices: range))])
        }
        if words.contains("pdf"), inputs.contains(where: { $0.kind == .image }) {
            var steps = [TaskStep(operation: .imagesToPDF, source: .artifacts(ids))]
            if let sizeTarget, let createPDF = steps.last {
                steps.append(TaskStep(operation: .compressPDF, source: .previousStep(createPDF.id), arguments: .pdfCompression(maxBytes: sizeTarget)))
            }
            return TaskPlan(request: request, steps: steps)
        }
        if let pdf = inputs.first(where: { $0.kind == .pdf }),
           sizeTarget != nil || words.contains("compress") || words.contains("smaller") {
            return TaskPlan(request: request, steps: [TaskStep(operation: .compressPDF, source: .artifacts([pdf.id]), arguments: .pdfCompression(maxBytes: sizeTarget))])
        }
        if words.contains("resize"), let image = inputs.first(where: { $0.kind == .image }),
           let width = Self.imageWidth(in: request), (1...20_000).contains(width) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .resizeImage, source: .artifacts([image.id]), arguments: .imageResize(width: width))])
        }
        if words.contains("convert"), let image = inputs.first(where: { $0.kind == .image }),
           let format = ["png", "jpeg", "jpg"].first(where: words.contains) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .convertImage, source: .artifacts([image.id]), arguments: .imageConvert(format: format == "jpg" ? "jpeg" : format))])
        }
        if words.contains("rename"), !inputs.isEmpty,
           let start = request.range(of: "starting with", options: .caseInsensitive) {
            let suffix = request[start.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = suffix.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "," }).first.map(String.init) ?? ""
            if !prefix.isEmpty, prefix.count <= 64 {
                return TaskPlan(request: request, steps: [TaskStep(operation: .batchRename, source: .artifacts(ids), arguments: .rename(prefix: prefix))])
            }
        }
        if words.contains("zip"), !inputs.isEmpty {
            return TaskPlan(request: request, steps: [TaskStep(operation: .createArchive, source: .artifacts(ids))])
        }
        if (words.contains("extract") || words.contains("save")), words.contains("audio"),
           let video = inputs.first(where: { $0.kind == .video }) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .extractAudio, source: .artifacts([video.id]))])
        }
        let clarification: String
        if inputs.isEmpty { clarification = "Add one or more files, then tell me what you want done." }
        else { clarification = "I don't have a reliable local workflow for that request yet. Try merging PDFs, turning images into a PDF, resizing or converting an image, renaming files, removing PDF pages, or extracting audio from a video." }
        return TaskPlan(request: request, steps: [], clarification: clarification)
    }

    private static func words(in request: String) -> Set<String> {
        Set(request.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    private static func imageWidth(in request: String) -> Int? {
        let patterns = [
            #"(?i)\b(\d{1,5})\s*(?:pixels?|px)\b"#,
            #"(?i)\b(?:width|wide)\s*(?:to|of|=)?\s*(\d{1,5})\b"#,
            #"(?i)\bto\s+(\d{1,5})(?:\s*(?:pixels?|px))?(?:\s+wide)?\b"#
        ]
        for pattern in patterns {
            if let value = firstCapture(pattern, in: request)?.first, let width = Int(value) { return width }
        }
        return nil
    }

    private static func pageRange(in request: String) -> [Int]? {
        let pattern = #"(?i)\bpages?\s+(\d+(?:\s*(?:,|and|through|to|[-–])\s*\d+)*)"#
        guard let selection = firstCapture(pattern, in: request)?.first else { return nil }
        let numberCaptures = allCaptures(#"\d+"#, in: selection).compactMap(Int.init)
        guard !numberCaptures.isEmpty, numberCaptures.allSatisfy({ (1...100_000).contains($0) }) else { return nil }
        if numberCaptures.count == 2,
           selection.range(of: #"(?i)\b(?:through|to)\b|[-–]"#, options: .regularExpression) != nil {
            let first = numberCaptures[0]
            let last = numberCaptures[1]
            guard last >= first, last - first < 200 else { return nil }
            return Array(first...last)
        }
        return Array(Set(numberCaptures)).sorted()
    }

    private static func firstCapture(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let source = text as NSString
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
    }

    private static func allCaptures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { source.substring(with: $0.range) }
    }

    private static func byteLimit(in request: String) -> Int64? {
        let tokens = request.lowercased().split(whereSeparator: \.isWhitespace).map {
            String($0.trimmingCharacters(in: .punctuationCharacters))
        }
        for index in tokens.indices {
            var numberText: String?
            var unitText: String?
            let token = tokens[index]
            for unit in ["megabytes", "megabyte", "gigabytes", "gigabyte", "kilobytes", "kilobyte", "mb", "gb", "kb"] where token != unit && token.hasSuffix(unit) {
                numberText = String(token.dropLast(unit.count))
                unitText = unit
                break
            }
            if unitText == nil, ["mb", "gb", "kb", "megabytes", "megabyte", "gigabytes", "gigabyte", "kilobytes", "kilobyte"].contains(token), index > tokens.startIndex {
                numberText = tokens[tokens.index(before: index)]
                unitText = token
            }
            guard let numberText, let unitText, let amount = Double(numberText), amount > 0 else { continue }
            let multiplier: Double
            if unitText.hasPrefix("g") { multiplier = 1_000_000_000 }
            else if unitText.hasPrefix("m") { multiplier = 1_000_000 }
            else { multiplier = 1_000 }
            let bytes = amount * multiplier
            if bytes <= 100_000_000_000 { return Int64(bytes.rounded(.down)) }
        }
        return nil
    }
}
