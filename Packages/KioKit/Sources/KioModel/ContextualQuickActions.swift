import Foundation
import KioCore

public struct ContextualQuickAction: Identifiable, Sendable, Equatable {
    public let title: String
    public let prompt: String
    public let requiresUserInput: Bool

    public var id: String { title + "\u{0}" + prompt }

    public init(title: String, prompt: String, requiresUserInput: Bool = false) {
        self.title = title
        self.prompt = prompt
        self.requiresUserInput = requiresUserInput
    }
}

/// Suggestions are request text routed through the normal planner and executor.
public enum ContextualQuickActionCatalog {
    public static func suggestions(for artifacts: [ArtifactRef]) -> [ContextualQuickAction] {
        guard !artifacts.isEmpty else { return [] }
        let kinds = artifacts.map(\.kind)
        let pdfs = kinds.filter { $0 == .pdf }.count
        let images = kinds.filter { $0 == .image }.count
        let tables = kinds.filter { $0 == .csv || $0 == .table }.count
        var actions: [ContextualQuickAction] = []

        if pdfs > 0 && images > 0 && artifacts.allSatisfy({ $0.kind == .pdf || $0.kind == .image }) {
            actions.append(.init(title: "Combine PDF + images", prompt: "Combine these PDFs and images into one PDF"))
        } else if pdfs > 1 && artifacts.allSatisfy({ $0.kind == .pdf }) {
            actions.append(.init(title: "Merge", prompt: "Merge these PDFs"))
        }
        if pdfs == 1 && artifacts.count == 1 {
            actions += [
                .init(title: "Compress", prompt: "Compress this PDF"),
                .init(title: "OCR", prompt: "OCR this PDF"),
                .init(title: "Pages…", prompt: "Extract pages from this PDF: ", requiresUserInput: true),
                .init(title: "Summarize", prompt: "Summarize this PDF")
            ]
        }

        if images > 0 && artifacts.allSatisfy({ $0.kind == .image }) {
            let plural = images > 1
            actions += [
                .init(title: "Resize 1200 px", prompt: plural ? "Resize these images to 1200 pixels wide" : "Resize this image to 1200 pixels wide"),
                .init(title: "PNG", prompt: plural ? "Convert these images to PNG" : "Convert this image to PNG"),
                .init(title: "OCR", prompt: plural ? "Extract text from these images" : "Extract the text from this image"),
                .init(title: "Make PDF", prompt: "Make a PDF from these images")
            ]
            if images == 1 {
                actions += [
                    .init(title: "Compress", prompt: "Compress this image"),
                    .init(title: "Receipt", prompt: "Extract the fields from this receipt"),
                    .init(title: "Remove background", prompt: "Remove the background from this image")
                ]
            }
            if images == 2 { actions.append(.init(title: "Compare", prompt: "Compare these images")) }
        }

        if tables > 0 && artifacts.allSatisfy({ $0.kind == .csv || $0.kind == .table }) {
            if tables == 1 {
                actions += [
                    .init(title: "Inspect", prompt: "Inspect this table"),
                    .init(title: "Clean", prompt: "Normalize this table"),
                    .init(title: "Summarize", prompt: "Summarize this table")
                ]
            }
            actions.append(.init(title: "Deduplicate", prompt: "Remove duplicate rows"))
        }

        if artifacts.count == 1, let artifact = artifacts.first {
            switch artifact.kind {
            case .url:
                actions += [
                    .init(title: "Summarize", prompt: "Summarize this page"),
                    .init(title: "Links", prompt: "Extract links from this page")
                ]
            case .video:
                actions += [
                    .init(title: "Compress", prompt: "Compress this video"),
                    .init(title: "Extract audio", prompt: "Extract audio from this video"),
                    .init(title: "Transcribe", prompt: "Transcribe this video")
                ]
            case .audio:
                actions += [
                    .init(title: "Transcribe", prompt: "Transcribe this audio"),
                    .init(title: "Subtitles", prompt: "Generate subtitles for this audio")
                ]
            case .text:
                actions += [
                    .init(title: "Summarize", prompt: "Summarize this text"),
                    .init(title: "Proofread", prompt: "Proofread this text")
                ]
                if ["swift", "py", "js", "jsx", "ts", "tsx", "rs", "go", "java", "c", "cpp", "cs", "rb", "php", "sh", "html", "css", "xml", "yaml", "yml", "toml", "sql", "kt", "kts", "dart", "vue", "svelte"].contains(artifact.fileURL.pathExtension.lowercased()) {
                    actions += [
                        .init(title: "Explain code", prompt: "Explain this code"),
                        .init(title: "Propose patch", prompt: "Propose a patch for this code")
                    ]
                }
            default:
                break
            }
        }

        return actions
    }
}
