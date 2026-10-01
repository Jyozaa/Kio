import Foundation
import ImageIO
import Vision
import KioCore

enum LensWorkflow {
    private struct OCRLine {
        let text: String
        let confidence: Float
        let box: CGRect
    }

    private struct OCRCell {
        let text: String
        let x: CGFloat
    }

    static func execute(_ operation: ToolOperation, inputs: [ArtifactRef]) throws -> [ArtifactRef] {
        guard !inputs.isEmpty, inputs.count <= 8, inputs.allSatisfy({ $0.kind == .image }) else {
            throw KioFailure.invalidInput("Lens accepts one to eight readable image files at a time.")
        }
        switch operation {
        case .ocrImage, .extractStructuredText:
            return try inputs.map { input in
                let lines = try recognize(input)
                let body = lines.map(\.text).joined(separator: "\n")
                let detail = lines.enumerated().map { index, line in
                    "| \(index + 1) | \(Self.markdown(line.text)) | \(String(format: "%.3f", line.confidence)) | \(String(format: "%.4f, %.4f, %.4f, %.4f", line.box.minX, line.box.minY, line.box.width, line.box.height)) |"
                }.joined(separator: "\n")
                let result = """
                # OCR — \(input.displayName)

                \(body)

                ## Recognition audit

                Coordinates are normalized to the image bounds (origin at lower left). Text below is the literal Vision recognition result.

                | Line | Text | Confidence | x, y, width, height |
                |---:|---|---:|---|
                \(detail)
                """
                return try write(result, for: input, baseName: Self.base(input.displayName) + "-OCR", ext: "md", kind: .text)
            }
        case .extractReceipt:
            guard inputs.count == 1, let input = inputs.first else { throw KioFailure.invalidInput("Extract one receipt or invoice image at a time.") }
            let lines = try recognize(input)
            return [try write(Self.receiptJSON(lines), for: input, baseName: Self.base(input.displayName) + "-Receipt", ext: "json", kind: .table)]
        case .extractImageTable:
            guard inputs.count == 1, let input = inputs.first else { throw KioFailure.invalidInput("Extract one pictured table at a time.") }
            let lines = try recognize(input)
            let rows = try tableRows(lines)
            let csv = rows.map { $0.map(Self.csv).joined(separator: ",") }.joined(separator: "\n") + "\n"
            let table = try write(csv, for: input, baseName: Self.base(input.displayName) + "-Table", ext: "csv", kind: .csv)
            let audit = lines.map { "- y=\(String(format: "%.4f", $0.box.midY)), x=\(String(format: "%.4f", $0.box.minX)), confidence=\(String(format: "%.3f", $0.confidence)): \($0.text)" }.joined(separator: "\n")
            let notes = "# OCR source for \(input.displayName)\n\nThe CSV row and cell text were segmented from these literal OCR lines. No model-generated cells were added.\n\n\(audit)"
            let evidence = try write(notes, for: input, baseName: Self.base(input.displayName) + "-Table-OCR", ext: "md", kind: .text)
            return [table, evidence]
        default:
            throw KioFailure.unsupported("Lens does not support that operation.")
        }
    }

    private static func recognize(_ input: ArtifactRef) throws -> [OCRLine] {
        try Task.checkCancellation()
        guard input.sizeBytes > 0, input.sizeBytes <= 50 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithURL(input.fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000, width * height <= 150_000_000 else {
            throw KioFailure.invalidInput("Choose a readable image no larger than 50 MB and 150 megapixels.")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.004
        do {
            try VNImageRequestHandler(url: input.fileURL, options: [:]).perform([request])
        } catch {
            throw KioFailure.processing("Lens couldn't read this image: \(error.localizedDescription)")
        }
        let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return OCRLine(text: text, confidence: candidate.confidence, box: observation.boundingBox)
        }
        guard !lines.isEmpty else { throw KioFailure.processing("Lens couldn't recognize readable text in this image.") }
        return lines.sorted { lhs, rhs in
            lhs.box.midY == rhs.box.midY ? lhs.box.minX < rhs.box.minX : lhs.box.midY > rhs.box.midY
        }
    }

    private static func tableRows(_ lines: [OCRLine]) throws -> [[String]] {
        var visualRows: [[OCRLine]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let last = visualRows.indices.last,
               abs((visualRows[last].map(\.box.midY).reduce(0, +) / CGFloat(visualRows[last].count)) - line.box.midY) <= 0.018 {
                visualRows[last].append(line)
            } else { visualRows.append([line]) }
        }
        let cellRows: [[OCRCell]] = visualRows.map { row in
            row.flatMap { line -> [OCRCell] in
                let parts = splitCells(line.text)
                guard parts.count > 1 else { return [OCRCell(text: line.text, x: line.box.minX)] }
                var searchFrom = line.text.startIndex
                return parts.map { part in
                    let found = line.text.range(of: part, range: searchFrom..<line.text.endIndex)
                    if let found { searchFrom = found.upperBound }
                    let offset = found.map { line.text.distance(from: line.text.startIndex, to: $0.lowerBound) } ?? 0
                    let x = line.box.minX + line.box.width * CGFloat(offset) / CGFloat(max(1, line.text.count))
                    return OCRCell(text: part, x: x)
                }
            }.sorted { $0.x < $1.x }
        }
        let anchors = cellRows.flatMap { $0.map(\.x) }.sorted()
        var columns: [CGFloat] = []
        for anchor in anchors where columns.allSatisfy({ abs($0 - anchor) > 0.055 }) { columns.append(anchor) }
        guard columns.count >= 2, cellRows.count >= 2 else {
            throw KioFailure.verification("Lens found text, but not enough consistent row and column structure for a safe table. Try a sharper image with visible cell spacing.")
        }
        guard columns.count <= 100 else { throw KioFailure.unsupported("Lens limits extracted tables to 100 columns.") }
        var result: [[String]] = []
        for row in cellRows.prefix(10_001) {
            var output = Array(repeating: "", count: columns.count)
            for cell in row {
                guard let index = columns.indices.min(by: { abs(columns[$0] - cell.x) < abs(columns[$1] - cell.x) }) else { continue }
                if output[index].isEmpty { output[index] = cell.text }
                else { output[index] += " " + cell.text }
            }
            if output.contains(where: { !$0.isEmpty }) { result.append(output) }
        }
        return result
    }

    private static func splitCells(_ line: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\s{2,}|\s*\|\s*|\t+"#) else { return [line] }
        let fullRange = NSRange(line.startIndex..., in: line)
        var pieces: [String] = []
        var cursor = line.startIndex
        for match in regex.matches(in: line, range: fullRange) {
            guard let range = Range(match.range, in: line) else { continue }
            let piece = line[cursor..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            cursor = range.upperBound
        }
        let tail = line[cursor...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces.count > 1 ? pieces : [line]
    }

    private static func receiptJSON(_ lines: [OCRLine]) -> String {
        let text = lines.map(\.text)
        let fullText = text.joined(separator: "\n")
        let merchant = text.prefix(3).first { line in
            !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            line.range(of: #"(?i)\b(?:receipt|invoice|tax|total|subtotal)\b"#, options: .regularExpression) == nil &&
            extractAmount(line) == nil
        }
        let date = firstMatch(#"\b(?:20\d{2}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.]\d{1,2}[-/.](?:\d{2}|\d{4}))\b"#, in: fullText)
        func labeled(_ labels: String) -> NSNumber? {
            for line in text where line.range(of: #"(?i)\b(?:\#(labels))\b"#, options: .regularExpression) != nil {
                if let amount = extractAmount(line) { return NSNumber(value: amount) }
            }
            return nil
        }
        let currency: String?
        if fullText.contains("£") { currency = "GBP" }
        else if fullText.contains("€") { currency = "EUR" }
        else if fullText.contains("¥") { currency = "JPY" }
        else if fullText.contains("$") { currency = "USD" }
        else { currency = nil }
        let object: [String: Any] = [
            "merchant": merchant as Any? ?? NSNull(),
            "date": date as Any? ?? NSNull(),
            "currency": currency as Any? ?? NSNull(),
            "subtotal": labeled("subtotal") as Any? ?? NSNull(),
            "tax": labeled("tax|vat|gst") as Any? ?? NSNull(),
            "total": labeled("total|amount due") as Any? ?? NSNull(),
            "items": [[String: Any]](),
            "source": ["file": "OCR source lines are retained in this extraction record.", "lines": lines.map { ["text": $0.text, "confidence": Double($0.confidence), "box": [$0.box.minX, $0.box.minY, $0.box.width, $0.box.height]] as [String: Any] }]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private static func extractAmount(_ line: String) -> Double? {
        guard let raw = firstMatch(#"(?:\d{1,3}(?:,\d{3})+|\d+)[.]\d{2}"#, in: line) else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: ""))
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    private static func write(_ text: String, for input: ArtifactRef, baseName: String, ext: String, kind: ArtifactKind) throws -> ArtifactRef {
        let output = try OutputLocation.makeURL(for: [input], baseName: baseName, fileExtension: ext)
        let temporary = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data(text.utf8).write(to: temporary, options: .atomic)
        try OutputLocation.commit(temporary, to: output)
        return ArtifactRef(id: UUID(), displayName: output.lastPathComponent, kind: kind, fileURL: output,
                           sizeBytes: Int64((try? Data(contentsOf: output, options: .mappedIfSafe).count) ?? 0), parentID: input.id)
    }

    private static func csv(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    private static func markdown(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
    private static func base(_ value: String) -> String {
        URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
    }
}
