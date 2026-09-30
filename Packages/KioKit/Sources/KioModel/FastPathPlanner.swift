import Foundation
import KioCore

public struct PlanningContext: Sendable {
    public let activeOutput: ArtifactRef?
    public let previousOperation: ToolOperation?
    public let previousPlan: TaskPlan?

    public init(activeOutput: ArtifactRef? = nil, previousOperation: ToolOperation? = nil, previousPlan: TaskPlan? = nil) {
        self.activeOutput = activeOutput
        self.previousOperation = previousOperation
        self.previousPlan = previousPlan
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

        if (words.contains("same") || words.contains("again")),
           (words.contains("these") || words.contains("files") || words.contains("ones")),
           let previous = context.previousPlan,
           !inputs.isEmpty {
            if let replayed = Self.replayableSteps(previous.steps, with: inputs) {
                return TaskPlan(request: request, steps: replayed)
            }
            return TaskPlan(request: request, steps: [], clarification: "The previous workflow doesn't fit these file types or can't be safely repeated. Choose matching files or describe a new operation.")
        }

        if context.previousOperation == .resizeImage,
           let image = inputs.first(where: { $0.kind == .image }),
           let width = Self.imageWidth(in: request), (1...20_000).contains(width),
           !words.contains("resize") {
            return TaskPlan(request: request, steps: [TaskStep(operation: .resizeImage, source: .artifacts([image.id]), arguments: .imageResize(width: width))])
        }

        if words.contains("merge"), inputs.filter({ $0.kind == .pdf }).count >= 2 {
            var steps = [TaskStep(operation: .mergePDFs, source: .artifacts(ids))]
            if let sizeTarget, let merge = steps.last {
                steps.append(TaskStep(operation: .compressPDF, source: .previousStep(merge.id), arguments: .pdfCompression(maxBytes: sizeTarget)))
            }
            return TaskPlan(request: request, steps: steps)
        }
        if words.contains("split"), let pdf = inputs.first(where: { $0.kind == .pdf }) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .splitPDF, source: .artifacts([pdf.id]))])
        }
        if words.contains("extract"), (words.contains("page") || words.contains("pages")),
           let pdf = inputs.first(where: { $0.kind == .pdf }), let pages = Self.pageRange(in: request) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .extractPDFPages, source: .artifacts([pdf.id]), arguments: .removePages(indices: pages))])
        }
        if words.contains("extract"), words.contains("text"), let pdf = inputs.first(where: { $0.kind == .pdf }) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .extractPDFText, source: .artifacts([pdf.id]))])
        }
        if (words.contains("ocr") || (words.contains("scan") && words.contains("text"))),
           let pdf = inputs.first(where: { $0.kind == .pdf }) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .ocrPDFText, source: .artifacts([pdf.id]))])
        }
        if words.contains("rotate"), let pdf = inputs.first(where: { $0.kind == .pdf }),
           let degrees = Self.rotationDegrees(in: request) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .rotatePDFPages, source: .artifacts([pdf.id]), arguments: .pdfRotation(indices: Self.pageRange(in: request) ?? [], degrees: degrees))])
        }
        if (words.contains("inspect") || (words.contains("page") && words.contains("count"))),
           let pdf = inputs.first(where: { $0.kind == .pdf }) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .inspectPDF, source: .artifacts([pdf.id]))])
        }
        if words.contains("remove"), words.contains("blank"), (words.contains("page") || words.contains("pages")),
           let pdf = inputs.first(where: { $0.kind == .pdf }) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .removeBlankPDFPages, source: .artifacts([pdf.id]))])
        }
        if words.contains("reorder"), (words.contains("page") || words.contains("pages")),
           let pdf = inputs.first(where: { $0.kind == .pdf }), let order = Self.pageOrder(in: request) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .reorderPDFPages, source: .artifacts([pdf.id]), arguments: .pageOrder(indices: order))])
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
        if words.contains("rotate"), let image = inputs.first(where: { $0.kind == .image }),
           let degrees = Self.rotationDegrees(in: request) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .rotateImage, source: .artifacts([image.id]), arguments: .imageRotation(degrees: degrees))])
        }
        if words.contains("inspect"), let image = inputs.first(where: { $0.kind == .image }) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .inspectImage, source: .artifacts([image.id]))])
        }
        if words.contains("contact"), words.contains("sheet"), inputs.count >= 2, inputs.count <= 36,
           inputs.allSatisfy({ $0.kind == .image }) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .imageContactSheet, source: .artifacts(ids))])
        }
        if words.contains("crop"), let image = inputs.first(where: { $0.kind == .image }),
           let rectangle = Self.cropRectangle(in: request) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .cropImage, source: .artifacts([image.id]),
                                                               arguments: .imageCrop(x: rectangle.0, y: rectangle.1, width: rectangle.2, height: rectangle.3))])
        }
        if words.contains("metadata"), words.contains("remove"), let image = inputs.first(where: { $0.kind == .image }) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .removeImageMetadata, source: .artifacts([image.id]))])
        }
        if let image = inputs.first(where: { $0.kind == .image }), sizeTarget != nil || words.contains("compress") || words.contains("smaller") {
            return TaskPlan(request: request, steps: [TaskStep(operation: .compressImage, source: .artifacts([image.id]), arguments: .imageCompression(maxBytes: sizeTarget))])
        }
        if words.contains("convert"), let image = inputs.first(where: { $0.kind == .image }),
           let format = ["png", "jpeg", "jpg"].first(where: words.contains) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .convertImage, source: .artifacts([image.id]), arguments: .imageConvert(format: format == "jpg" ? "jpeg" : format))])
        }
        if words.contains("rename"), inputs.count == 1, let name = Self.exactRenameName(in: request) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .renameFile, source: .artifacts([inputs[0].id]), arguments: .exactRename(name: name))])
        }
        if words.contains("rename"), !inputs.isEmpty,
           let start = request.range(of: "starting with", options: .caseInsensitive) {
            let suffix = request[start.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = suffix.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "," }).first.map(String.init) ?? ""
            if !prefix.isEmpty, prefix.count <= 64 {
                return TaskPlan(request: request, steps: [TaskStep(operation: .batchRename, source: .artifacts(ids), arguments: .rename(prefix: prefix))])
            }
        }
        if words.contains("copy") || words.contains("copies") {
            if let folder = inputs.first(where: { $0.kind == .folder }) {
                let files = inputs.filter { $0.kind != .folder }
                if !files.isEmpty {
                    return TaskPlan(request: request, steps: [TaskStep(operation: .copyFiles, source: .artifacts(files.map(\.id) + [folder.id]))])
                }
            }
        }
        if words.contains("move") || words.contains("relocate") || words.contains("transfer") {
            if let folder = inputs.first(where: { $0.kind == .folder }) {
                let files = inputs.filter { $0.kind != .folder }
                if !files.isEmpty {
                    return TaskPlan(request: request, steps: [TaskStep(operation: .moveFiles, source: .artifacts(files.map(\.id) + [folder.id]))])
                }
            }
        }
        if words.contains("create"), words.contains("folder"), let parent = inputs.first(where: { $0.kind == .folder }),
           let name = Self.folderName(in: request) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .createFolder, source: .artifacts([parent.id]), arguments: .folderName(name: name))])
        }
        if words.contains("find"), words.contains("duplicate"), inputs.count >= 2, inputs.allSatisfy({ $0.kind != .folder }) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .findDuplicates, source: .artifacts(ids))])
        }
        if (words.contains("organize") || words.contains("sort")), !inputs.isEmpty, inputs.allSatisfy({ $0.kind != .folder }) {
            let operation: ToolOperation = (words.contains("date") || words.contains("month") || words.contains("year")) ? .organizeByDate : .organizeByType
            return TaskPlan(request: request, steps: [TaskStep(operation: operation, source: .artifacts(ids))])
        }
        if words.contains("inspect"), let archive = inputs.first(where: { $0.kind == .other && $0.fileURL.pathExtension.lowercased() == "zip" }) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .inspectArchive, source: .artifacts([archive.id]))])
        }
        if words.contains("extract"), words.contains("zip"), let archive = inputs.first(where: { $0.kind == .other && $0.fileURL.pathExtension.lowercased() == "zip" }) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .extractZip, source: .artifacts([archive.id]))])
        }
        if words.contains("zip"), !inputs.isEmpty {
            return TaskPlan(request: request, steps: [TaskStep(operation: .createArchive, source: .artifacts(ids))])
        }
        if let video = inputs.first(where: { $0.kind == .video }) {
            if words.contains("inspect") || words.contains("details") || words.contains("info") {
                return TaskPlan(request: request, steps: [TaskStep(operation: .inspectMedia, source: .artifacts([video.id]))])
            }
            if words.contains("thumbnail") || words.contains("frame") {
                let time = Self.videoTimeMilliseconds(in: request) ?? 0
                return TaskPlan(request: request, steps: [TaskStep(operation: .thumbnailVideo, source: .artifacts([video.id]), arguments: .mediaThumbnail(timeMilliseconds: time))])
            }
            if words.contains("trim"), let range = Self.videoTrimRange(in: request) {
                return TaskPlan(request: request, steps: [TaskStep(operation: .trimVideo, source: .artifacts([video.id]),
                                                                   arguments: .mediaTrim(startMilliseconds: range.0, durationMilliseconds: range.1))])
            }
            if words.contains("resize"), let width = Self.imageWidth(in: request), [640, 960, 1280].contains(width) {
                return TaskPlan(request: request, steps: [TaskStep(operation: .resizeVideo, source: .artifacts([video.id]), arguments: .mediaResize(width: width))])
            }
            if words.contains("transcode") || words.contains("convert") {
                return TaskPlan(request: request, steps: [TaskStep(operation: .transcodeVideo, source: .artifacts([video.id]))])
            }
            if sizeTarget != nil || words.contains("compress") || words.contains("smaller") {
                let target = sizeTarget.flatMap { $0 <= 10_000_000_000 ? $0 : nil }
                return TaskPlan(request: request, steps: [TaskStep(operation: .compressVideo, source: .artifacts([video.id]), arguments: .mediaCompression(maxBytes: target))])
            }
        }
        if (words.contains("extract") || words.contains("save")), words.contains("audio"),
           let video = inputs.first(where: { $0.kind == .video }) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .extractAudio, source: .artifacts([video.id]))])
        }
        let clarification: String
        if inputs.isEmpty { clarification = "Add one or more files, then tell me what you want done." }
        else { clarification = "I don't have a reliable local workflow for that request yet. Try merging, splitting, inspecting, or editing PDF pages; converting or resizing images; renaming files; creating a ZIP; or extracting audio from a video." }
        return TaskPlan(request: request, steps: [], clarification: clarification)
    }

    private static func words(in request: String) -> Set<String> {
        Set(request.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    private static func supports(_ operation: ToolOperation, kinds: [ArtifactKind]) -> Bool {
        switch operation {
        case .mergePDFs: kinds.count >= 2 && kinds.allSatisfy { $0 == .pdf }
        case .removePDFPages, .removeBlankPDFPages, .splitPDF, .extractPDFPages, .reorderPDFPages, .rotatePDFPages, .extractPDFText, .ocrPDFText, .inspectPDF, .compressPDF:
            kinds.count == 1 && kinds[0] == .pdf
        case .imagesToPDF: !kinds.isEmpty && kinds.allSatisfy { $0 == .image }
        case .resizeImage, .convertImage, .rotateImage, .inspectImage, .cropImage, .compressImage, .removeImageMetadata: kinds.count == 1 && kinds[0] == .image
        case .imageContactSheet: kinds.count >= 2 && kinds.count <= 36 && kinds.allSatisfy { $0 == .image }
        case .renameFile: kinds.count == 1
        case .copyFiles, .moveFiles: kinds.count >= 2 && kinds.last == .folder && kinds.dropLast().allSatisfy { $0 != .folder }
        case .createFolder: kinds.count == 1 && kinds[0] == .folder
        case .findDuplicates: kinds.count >= 2 && kinds.count <= 200 && kinds.allSatisfy { $0 != .folder }
        case .organizeByType, .organizeByDate: !kinds.isEmpty && kinds.count <= 200 && kinds.allSatisfy { $0 != .folder }
        case .batchRename, .createArchive: !kinds.isEmpty
        case .inspectArchive, .extractZip: kinds.count == 1 && kinds[0] == .other
        case .extractAudio, .inspectMedia, .thumbnailVideo, .trimVideo, .resizeVideo, .transcodeVideo, .compressVideo: kinds.count == 1 && kinds[0] == .video
        }
    }

    /// Rebuilds only known pipeline shapes from registered operations. Source IDs and step IDs
    /// always belong to this request; no previous file reference is carried into the new plan.
    private static func replayableSteps(_ previous: [TaskStep], with inputs: [ArtifactRef]) -> [TaskStep]? {
        guard !previous.isEmpty, inputs.allSatisfy({ $0.isAvailableLocally }) else { return nil }
        guard case .artifacts(let oldSourceIDs) = previous[0].source,
              !oldSourceIDs.isEmpty,
              Set(oldSourceIDs).count == oldSourceIDs.count else { return nil }

        let allowedShape: Bool
        switch previous.count {
        case 1:
            allowedShape = true
        case 2:
            allowedShape = (previous[0].operation == .mergePDFs || previous[0].operation == .imagesToPDF)
                && previous[1].operation == .compressPDF
                && previous[1].source == .previousStep(previous[0].id)
        default:
            allowedShape = false
        }
        guard allowedShape, previous.allSatisfy({ validArguments($0.arguments, for: $0.operation) }) else { return nil }

        let originalKinds = inputs.map(\.kind)
        guard supports(previous[0].operation, kinds: originalKinds) else { return nil }

        var rebuilt: [TaskStep] = []
        var previousOutputKinds = resultKinds(for: previous[0].operation, inputKinds: originalKinds)
        let first = TaskStep(operation: previous[0].operation, source: .artifacts(inputs.map(\.id)),
                             arguments: previous[0].arguments)
        rebuilt.append(first)

        for prior in previous.dropFirst() {
            guard supports(prior.operation, kinds: previousOutputKinds) else { return nil }
            let step = TaskStep(operation: prior.operation, source: .previousStep(rebuilt[rebuilt.count - 1].id),
                                arguments: prior.arguments)
            rebuilt.append(step)
            previousOutputKinds = resultKinds(for: prior.operation, inputKinds: previousOutputKinds)
        }
        return rebuilt
    }

    private static func validArguments(_ arguments: ToolArguments, for operation: ToolOperation) -> Bool {
        switch operation {
        case .mergePDFs, .removeBlankPDFPages, .splitPDF, .extractPDFText, .ocrPDFText, .inspectPDF, .imagesToPDF, .inspectImage, .removeImageMetadata, .imageContactSheet, .createArchive, .inspectArchive, .extractZip, .extractAudio, .inspectMedia, .transcodeVideo,
             .findDuplicates, .organizeByType, .organizeByDate:
            arguments == .none
        case .removePDFPages, .extractPDFPages:
            if case .removePages(let indices) = arguments {
                !indices.isEmpty && indices.allSatisfy { (1...100_000).contains($0) } && Set(indices).count == indices.count
            } else { false }
        case .reorderPDFPages:
            if case .pageOrder(let indices) = arguments {
                (1...300).contains(indices.count) && indices.allSatisfy { (1...300).contains($0) } && Set(indices).count == indices.count
            } else { false }
        case .rotatePDFPages:
            if case .pdfRotation(let indices, let degrees) = arguments {
                indices.count <= 200 && indices.allSatisfy { (1...100_000).contains($0) } && [90, 180, 270].contains(degrees)
            } else { false }
        case .resizeImage:
            if case .imageResize(let width) = arguments { (1...20_000).contains(width) } else { false }
        case .convertImage:
            if case .imageConvert(let format) = arguments { ["png", "jpeg"].contains(format) } else { false }
        case .rotateImage:
            if case .imageRotation(let degrees) = arguments { [90, 180, 270].contains(degrees) } else { false }
        case .cropImage:
            if case .imageCrop(let x, let y, let width, let height) = arguments {
                (0...20_000).contains(x) && (0...20_000).contains(y) && (1...20_000).contains(width) && (1...20_000).contains(height) && x + width <= 20_000 && y + height <= 20_000
            } else { false }
        case .compressImage:
            if case .imageCompression(let maxBytes) = arguments { maxBytes.map { (1...1_000_000_000).contains($0) } ?? true } else { false }
        case .thumbnailVideo:
            if case .mediaThumbnail(let time) = arguments { (0...86_400_000).contains(time) } else { false }
        case .trimVideo:
            if case .mediaTrim(let start, let duration) = arguments { (0...86_400_000).contains(start) && (1...86_400_000).contains(duration) && start + duration <= 86_400_000 } else { false }
        case .resizeVideo:
            if case .mediaResize(let width) = arguments { [640, 960, 1280].contains(width) } else { false }
        case .compressVideo:
            if case .mediaCompression(let maxBytes) = arguments { maxBytes.map { (1...10_000_000_000).contains($0) } ?? true } else { false }
        case .renameFile:
            if case .exactRename(let name) = arguments { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 100 } else { false }
        case .batchRename:
            if case .rename(let prefix) = arguments { !prefix.isEmpty && prefix.count <= 64 } else { false }
        case .copyFiles, .moveFiles:
            arguments == .none
        case .createFolder:
            if case .folderName(let name) = arguments { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 100 } else { false }
        case .compressPDF:
            if case .pdfCompression(let maxBytes) = arguments { maxBytes.map { $0 > 0 } ?? true } else { false }
        }
    }

    private static func resultKinds(for operation: ToolOperation, inputKinds: [ArtifactKind]) -> [ArtifactKind] {
        switch operation {
        case .mergePDFs, .removePDFPages, .removeBlankPDFPages, .splitPDF, .extractPDFPages, .reorderPDFPages, .rotatePDFPages, .imagesToPDF, .compressPDF: [.pdf]
        case .extractPDFText, .ocrPDFText, .inspectPDF, .inspectImage, .inspectArchive: [.text]
        case .resizeImage, .convertImage, .rotateImage, .cropImage, .compressImage, .removeImageMetadata, .imageContactSheet: [.image]
        case .renameFile, .batchRename: inputKinds
        case .copyFiles, .moveFiles: Array(inputKinds.dropLast())
        case .createFolder, .organizeByType, .organizeByDate: [.folder]
        case .findDuplicates: [.text]
        case .createArchive: [.other]
        case .extractZip: [.folder]
        case .extractAudio: [.audio]
        case .inspectMedia: [.text]
        case .thumbnailVideo: [.image]
        case .trimVideo, .resizeVideo, .transcodeVideo, .compressVideo: [.video]
        }
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

    private static func exactRenameName(in request: String) -> String? {
        let patterns = [
            #"(?i)\brename\b.*?\b(?:to|as)\s+([\"'“”‘’]?)(.+?)\1\s*[.!?]*$"#,
            #"(?i)\brename\s+(?:it|this|that)\s+([A-Za-z0-9][A-Za-z0-9 _.-]{0,100})\s*[.!?]*$"#
        ]
        for pattern in patterns {
            guard let captures = firstCapture(pattern, in: request), let value = captures.last else { continue }
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’ .,!?:;")))
            if !name.isEmpty, name.count <= 100 { return name }
        }
        return nil
    }

    private static func rotationDegrees(in request: String) -> Int? {
        let requestWords = words(in: request)
        if requestWords.contains("anticlockwise") || requestWords.contains("left")
            || (requestWords.contains("counter") && requestWords.contains("clockwise")) { return 270 }
        if requestWords.contains("clockwise") || requestWords.contains("right") { return 90 }
        for degrees in [90, 180, 270] where requestWords.contains(String(degrees)) { return degrees }
        return nil
    }

    private static func cropRectangle(in request: String) -> (Int, Int, Int, Int)? {
        guard let values = firstCapture(#"(?i)\bx\s*[=:]?\s*(\d+)\D+y\s*[=:]?\s*(\d+)\D+width\s*[=:]?\s*(\d+)\D+height\s*[=:]?\s*(\d+)\b"#, in: request),
              values.count == 4, let x = Int(values[0]), let y = Int(values[1]),
              let width = Int(values[2]), let height = Int(values[3]),
              (0...20_000).contains(x), (0...20_000).contains(y),
              (1...20_000).contains(width), (1...20_000).contains(height),
              x + width <= 20_000, y + height <= 20_000 else { return nil }
        return (x, y, width, height)
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

    private static func pageOrder(in request: String) -> [Int]? {
        guard let selection = firstCapture(#"(?i)\breorder(?:\s+the)?\s+pages?\s+([\d\s,;and-]+)"#, in: request)?.first else { return nil }
        let order = allCaptures(#"\d+"#, in: selection).compactMap(Int.init)
        guard (1...300).contains(order.count), order.allSatisfy({ (1...300).contains($0) }), Set(order).count == order.count else { return nil }
        return order
    }

    private static func videoTimeMilliseconds(in request: String) -> Int64? {
        guard let value = firstCapture(#"(?i)\b(?:at|around)\s+(\d+(?:\.\d+)?)\s*(?:s|sec|seconds?)\b"#, in: request)?.first,
              let seconds = Double(value), (0...86_400).contains(seconds) else { return nil }
        return Int64((seconds * 1_000).rounded())
    }

    private static func videoTrimRange(in request: String) -> (Int64, Int64)? {
        if let values = firstCapture(#"(?i)\bfrom\s+(\d+(?:\.\d+)?)\s*(?:s|sec|seconds?)\s+to\s+(\d+(?:\.\d+)?)\s*(?:s|sec|seconds?)"#, in: request),
           values.count == 2, let start = Double(values[0]), let end = Double(values[1]),
           start >= 0, end > start, end <= 86_400 {
            return (Int64((start * 1_000).rounded()), Int64(((end - start) * 1_000).rounded()))
        }
        if let values = firstCapture(#"(?i)\bstart(?:ing)?\s+(?:at\s+)?(\d+(?:\.\d+)?)\s*(?:s|sec|seconds?)\s+for\s+(\d+(?:\.\d+)?)\s*(?:s|sec|seconds?)"#, in: request),
           values.count == 2, let start = Double(values[0]), let duration = Double(values[1]),
           start >= 0, duration > 0, start + duration <= 86_400 {
            return (Int64((start * 1_000).rounded()), Int64((duration * 1_000).rounded()))
        }
        return nil
    }

    private static func folderName(in request: String) -> String? {
        guard let name = firstCapture(#"(?i)\b(?:named|called|name)\s+[\"'“”‘’]?(.+?)[\"'“”‘’]?\s*[.!?]*$"#, in: request)?.last else { return nil }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’.!?,")))
        return clean.isEmpty || clean.count > 100 ? nil : clean
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
