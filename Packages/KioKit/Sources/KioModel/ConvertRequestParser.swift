import Foundation
import KioCore

public enum ConvertRequest: Equatable, Sendable {
    case image(format: String?, width: Int?, maximumBytes: Int64?)
    case pdfCompression(maximumBytes: Int64?)
    case imagesToPDF
    case mergePDFs
    case audio(format: AudioTargetFormat)
    case extractAudio(format: AudioTargetFormat)
    case video(format: VideoTargetFormat?, width: Int?, maximumBytes: Int64?)
    case unsupported(String)

    public var operationTitle: String {
        switch self {
        case .image(let format, let width, let bytes):
            if let format { return "Converting to \(format.uppercased())…" }
            if let width { return "Resizing to \(width) px…" }
            if bytes != nil { return "Compressing image…" }
            return "Choose an image format"
        case .pdfCompression: return "Compressing PDF…"
        case .imagesToPDF: return "Preparing PDF…"
        case .mergePDFs: return "Merging PDFs…"
        case .audio(let format): return "Converting to \(format.rawValue.uppercased())…"
        case .extractAudio(let format): return "Extracting \(format.rawValue.uppercased()) audio…"
        case .video(let format, let width, _):
            if let width { return "Resizing video to \(width) px…" }
            return format.map { "Converting to \($0.rawValue.uppercased())…" } ?? "Converting video…"
        case .unsupported: return "Unsupported request"
        }
    }
}

/// Small deterministic parser for the Convert surface. This intentionally does not
/// guess transformations outside the supported conversion vocabulary.
public enum ConvertRequestParser {
    public static func parse(_ request: String, inputs: [ArtifactRef]) -> ConvertRequest? {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kinds = Set(inputs.map(\.kind))
        guard !inputs.isEmpty else { return nil }

        let bytes = requestedBytes(in: text)
        let width = requestedWidth(in: text)
        if kinds.contains(.image) {
            if kinds.contains(where: { $0 != .image }) && text.contains("pdf") { return nil }
            let format = imageFormat(in: text)
            if format != nil || width != nil || bytes != nil || text.contains("compress") || text.contains("smaller") {
                return .image(format: format, width: width, maximumBytes: bytes)
            }
        }
        if kinds.contains(.pdf) {
            if kinds == [.pdf], inputs.count > 1 { return text.contains("compress") || bytes != nil ? .pdfCompression(maximumBytes: bytes) : .mergePDFs }
            if text.contains("compress") || bytes != nil { return .pdfCompression(maximumBytes: bytes) }
            return .unsupported("Convert supports PDF compression and merging PDFs. For page edits, use Preview.")
        }
        if kinds.contains(.audio) || kinds.contains(.video) {
            let audioTarget = audioFormat(in: text)
            let audioIntent = text.contains("audio") || text.contains("sound") || audioTarget != nil
            if audioIntent {
                let target = audioTarget ?? .m4a
                return kinds.contains(.video) ? .extractAudio(format: target) : .audio(format: target)
            }
            let videoTarget = videoFormat(in: text)
            if kinds.contains(.video), videoTarget != nil || width != nil || bytes != nil || text.contains("compress") {
                return .video(format: videoTarget, width: width, maximumBytes: bytes)
            }
            if kinds == [.audio], let audioTarget { return .audio(format: audioTarget) }
        }
        if kinds.contains(.image), text.contains("pdf") { return .imagesToPDF }
        if text.isEmpty { return nil }
        return .unsupported("That transformation isn't supported by Convert. Choose a format, resize width, or file-size target.")
    }

    private static func requestedBytes(in text: String) -> Int64? {
        let pattern = #"(?:under|below|less than|at most|max(?:imum)?)\s*(\d+(?:\.\d+)?)\s*(kb|kib|mb|mib|gb|gib|bytes?)\b"#
        guard let range = text.range(of: pattern, options: .regularExpression),
              let match = text[range].range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression),
              let number = Double(text[match]), number > 0 else { return nil }
        let unit = text[range].lowercased()
        let factor: Double = unit.contains("gb") ? 1_000_000_000 : (unit.contains("mb") ? 1_000_000 : (unit.contains("kb") ? 1_000 : 1))
        let result = number * factor
        return result <= Double(Int64.max) ? Int64(result) : nil
    }

    private static func requestedWidth(in text: String) -> Int? {
        let pattern = #"\b(\d{2,5})\s*(?:px|pixels?)\b"#
        guard let match = text.range(of: pattern, options: .regularExpression),
              let digits = text[match].range(of: #"\d+"#, options: .regularExpression),
              let width = Int(text[digits]), (1...20_000).contains(width) else { return nil }
        return width
    }
    private static func imageFormat(in text: String) -> String? {
        if text.contains("jpeg") || text.contains("jpg") { return "jpeg" }
        for format in ["png", "heic", "heif", "webp", "tiff", "tif"] where text.contains(format) { return format }
        return nil
    }
    private static func audioFormat(in text: String) -> AudioTargetFormat? {
        for format in AudioTargetFormat.allCases where text.contains(format.rawValue) { return format }
        return nil
    }
    private static func videoFormat(in text: String) -> VideoTargetFormat? {
        for format in VideoTargetFormat.allCases where text.contains(format.rawValue) { return format }
        return nil
    }
}
