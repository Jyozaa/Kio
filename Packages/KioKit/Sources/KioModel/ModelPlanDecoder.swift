import Foundation
import KioCore

/// Converts model output into registered, typed tool steps. Model-provided names and
/// indexes are treated as untrusted data and are rejected unless they map to known inputs.
public enum ModelPlanDecoder {
    public static func decode(_ response: String, request: String, artifacts: [ArtifactRef]) -> TaskPlan? {
        guard response.utf8.count <= 32_000, let data = response.data(using: .utf8) else { return nil }
        let wire: WirePlan
        do { wire = try JSONDecoder().decode(WirePlan.self, from: data) }
        catch { return nil }
        guard wire.steps.count <= 8 else { return nil }

        if wire.steps.isEmpty {
            guard let text = wire.clarification?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return TaskPlan(request: request, steps: [], clarification: String(text.prefix(400)))
        }

        var steps: [TaskStep] = []
        var outputKinds: [[ArtifactKind]] = []
        for (index, candidate) in wire.steps.enumerated() {
            guard let operation = ToolOperation(rawValue: candidate.operation) else { return nil }
            if operation == .moveFiles, !hasExplicitMoveIntent(request) { return nil }
            if operation == .copyFiles, !hasExplicitCopyIntent(request) { return nil }
            let source: StepSource
            let inputKinds: [ArtifactKind]
            switch (candidate.inputIndexes, candidate.previousStepIndex) {
            case (.some(let indexes), .none):
                guard !indexes.isEmpty, indexes.count <= 32,
                      indexes.allSatisfy({ artifacts.indices.contains($0) }),
                      Set(indexes).count == indexes.count else { return nil }
                source = .artifacts(indexes.map { artifacts[$0].id })
                inputKinds = indexes.map { artifacts[$0].kind }
            case (.none, .some(let previous)):
                guard (0..<index).contains(previous), let kinds = outputKinds[safe: previous] else { return nil }
                source = .previousStep(steps[previous].id)
                inputKinds = kinds
            default:
                return nil
            }
            guard accepts(operation, kinds: inputKinds) else { return nil }
            guard let arguments = typedArguments(candidate.arguments, for: operation) else { return nil }

            let step = TaskStep(operation: operation, source: source, arguments: arguments)
            steps.append(step)
            outputKinds.append(resultKinds(for: operation, inputKinds: inputKinds))
        }
        return TaskPlan(request: request, steps: steps)
    }

    private static func accepts(_ operation: ToolOperation, kinds: [ArtifactKind]) -> Bool {
        switch operation {
        case .mergePDFs: kinds.count >= 2 && kinds.allSatisfy { $0 == .pdf }
        case .removePDFPages, .removeBlankPDFPages, .splitPDF, .extractPDFPages, .reorderPDFPages, .rotatePDFPages, .extractPDFText, .ocrPDFText, .inspectPDF, .compressPDF:
            kinds.count == 1 && kinds[0] == .pdf
        case .imagesToPDF: !kinds.isEmpty && kinds.allSatisfy { $0 == .image }
        case .resizeImage, .convertImage, .rotateImage, .inspectImage, .cropImage, .compressImage, .removeImageMetadata: kinds.count == 1 && kinds[0] == .image
        case .imageContactSheet: kinds.count >= 2 && kinds.count <= 36 && kinds.allSatisfy { $0 == .image }
        case .renameFile: kinds.count == 1
        case .copyFiles, .moveFiles:
            kinds.count >= 2 && kinds.count <= 33 && kinds.last == .folder && kinds.dropLast().allSatisfy { $0 != .folder }
        case .createFolder: kinds.count == 1 && kinds[0] == .folder
        case .findDuplicates:
            kinds.count >= 2 && kinds.count <= 200 && kinds.allSatisfy { $0 != .folder }
        case .organizeByType, .organizeByDate:
            !kinds.isEmpty && kinds.count <= 200 && kinds.allSatisfy { $0 != .folder }
        case .batchRename, .createArchive: !kinds.isEmpty
        case .inspectArchive, .extractZip: kinds.count == 1 && kinds[0] == .other
        case .extractAudio, .inspectMedia, .thumbnailVideo, .trimVideo, .resizeVideo, .transcodeVideo, .compressVideo: kinds.count == 1 && kinds[0] == .video
        }
    }

    private static func typedArguments(_ wire: WireArguments?, for operation: ToolOperation) -> ToolArguments? {
        switch operation {
        case .mergePDFs, .removeBlankPDFPages, .splitPDF, .extractPDFText, .ocrPDFText, .inspectPDF, .imagesToPDF, .inspectImage, .removeImageMetadata, .imageContactSheet, .createArchive, .inspectArchive, .extractZip, .extractAudio, .inspectMedia, .transcodeVideo,
             .copyFiles, .moveFiles, .findDuplicates, .organizeByType, .organizeByDate:
            return ToolArguments.none
        case .createFolder:
            guard let name = wire?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 100 else { return nil }
            return .folderName(name: name)
        case .removePDFPages, .extractPDFPages:
            guard let pages = wire?.pages, !pages.isEmpty, pages.count <= 200,
                  pages.allSatisfy({ (1...100_000).contains($0) }) else { return nil }
            return .removePages(indices: Array(Set(pages)).sorted())
        case .reorderPDFPages:
            guard let pages = wire?.pages, (1...300).contains(pages.count),
                  pages.allSatisfy({ (1...300).contains($0) }), Set(pages).count == pages.count else { return nil }
            return .pageOrder(indices: pages)
        case .rotatePDFPages:
            let pages = wire?.pages ?? []
            guard pages.count <= 200, pages.allSatisfy({ (1...100_000).contains($0) }),
                  let degrees = wire?.degrees, [90, 180, 270].contains(degrees) else { return nil }
            return .pdfRotation(indices: Array(Set(pages)).sorted(), degrees: degrees)
        case .resizeImage:
            guard let width = wire?.width, (1...20_000).contains(width) else { return nil }
            return .imageResize(width: width)
        case .convertImage:
            guard let format = wire?.format?.lowercased(), ["png", "jpg", "jpeg"].contains(format) else { return nil }
            return .imageConvert(format: format == "jpg" ? "jpeg" : format)
        case .rotateImage:
            guard let degrees = wire?.degrees, [90, 180, 270].contains(degrees) else { return nil }
            return .imageRotation(degrees: degrees)
        case .cropImage:
            guard let x = wire?.x, let y = wire?.y, let width = wire?.width, let height = wire?.height,
                  (0...20_000).contains(x), (0...20_000).contains(y),
                  (1...20_000).contains(width), (1...20_000).contains(height),
                  x + width <= 20_000, y + height <= 20_000 else { return nil }
            return .imageCrop(x: x, y: y, width: width, height: height)
        case .compressImage:
            if let maxBytes = wire?.maxBytes, !(1...1_000_000_000).contains(maxBytes) { return nil }
            return .imageCompression(maxBytes: wire?.maxBytes)
        case .thumbnailVideo:
            guard let time = wire?.timeMs ?? 0 as Int64?, (0...86_400_000).contains(time) else { return nil }
            return .mediaThumbnail(timeMilliseconds: time)
        case .trimVideo:
            guard let start = wire?.startMs, let duration = wire?.durationMs,
                  (0...86_400_000).contains(start), (1...86_400_000).contains(duration),
                  start + duration <= 86_400_000 else { return nil }
            return .mediaTrim(startMilliseconds: start, durationMilliseconds: duration)
        case .resizeVideo:
            guard let width = wire?.width, [640, 960, 1280].contains(width) else { return nil }
            return .mediaResize(width: width)
        case .compressVideo:
            if let maxBytes = wire?.maxBytes, !(1...10_000_000_000).contains(maxBytes) { return nil }
            return .mediaCompression(maxBytes: wire?.maxBytes)
        case .renameFile:
            guard let name = wire?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 100 else { return nil }
            return .exactRename(name: name)
        case .batchRename:
            guard let prefix = wire?.prefix?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prefix.isEmpty, prefix.count <= 64 else { return nil }
            return .rename(prefix: prefix)
        case .compressPDF:
            if let maxBytes = wire?.maxBytes, maxBytes <= 0 { return nil }
            return .pdfCompression(maxBytes: wire?.maxBytes)
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

    private struct WirePlan: Decodable {
        let steps: [WireStep]
        let clarification: String?
    }

    private static func hasExplicitMoveIntent(_ request: String) -> Bool {
        let normalized = request.lowercased()
        guard normalized.range(of: #"\b(?:move|relocate|transfer)\b"#, options: .regularExpression) != nil else { return false }
        return !["don't move", "do not move", "never move", "don't relocate", "do not relocate"].contains(where: normalized.contains)
    }

    private static func hasExplicitCopyIntent(_ request: String) -> Bool {
        request.lowercased().range(of: #"\b(?:copy|copies|duplicate)\b"#, options: .regularExpression) != nil
    }

    private struct WireStep: Decodable {
        let operation: String
        let inputIndexes: [Int]?
        let previousStepIndex: Int?
        let arguments: WireArguments?
    }

    private struct WireArguments: Decodable {
        let width: Int?
        let x: Int?
        let y: Int?
        let height: Int?
        let format: String?
        let name: String?
        let prefix: String?
        let pages: [Int]?
        let degrees: Int?
        let maxBytes: Int64?
        let timeMs: Int64?
        let startMs: Int64?
        let durationMs: Int64?
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
