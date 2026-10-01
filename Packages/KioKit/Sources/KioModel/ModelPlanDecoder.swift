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
            if operation == .researchOpenSources {
                guard case .artifacts(let ids) = source, ids.count == 1,
                      artifacts.first(where: { $0.id == ids[0] })?.fileURL.pathExtension.lowercased() == "kio-query" else { return nil }
            }
            guard accepts(operation, kinds: inputKinds) else { return nil }
            guard let arguments = typedArguments(candidate.arguments, for: operation, request: request) else { return nil }

            let step = TaskStep(operation: operation, source: source, arguments: arguments)
            steps.append(step)
            outputKinds.append(resultKinds(for: operation, inputKinds: inputKinds))
        }
        return TaskPlan(request: request, steps: steps)
    }

    private static func accepts(_ operation: ToolOperation, kinds: [ArtifactKind]) -> Bool {
        switch operation {
        case .mergePDFs: kinds.count >= 2 && kinds.allSatisfy { $0 == .pdf }
        case .combineMixedPDFInputs:
            (2...32).contains(kinds.count) && kinds.allSatisfy { $0 == .pdf || $0 == .image }
                && kinds.contains(.pdf) && kinds.contains(.image)
        case .removePDFPages, .removeBlankPDFPages, .splitPDF, .extractPDFPages, .reorderPDFPages, .rotatePDFPages, .inspectPDF, .compressPDF:
            kinds.count == 1 && kinds[0] == .pdf
        case .searchPDFText: kinds.count == 1 && kinds[0] == .pdf
        case .extractPDFText, .ocrPDFText: (1...8).contains(kinds.count) && kinds.allSatisfy { $0 == .pdf }
        case .imagesToPDF: !kinds.isEmpty && kinds.allSatisfy { $0 == .image }
        case .resizeImage, .convertImage, .rotateImage, .inspectImage, .cropImage, .smartCropImage, .compressImage, .removeImageMetadata, .removeImageBackground: kinds.count == 1 && kinds[0] == .image
        case .batchResizeImages, .batchConvertImages: (1...32).contains(kinds.count) && kinds.allSatisfy { $0 == .image }
        case .compareImages: kinds.count == 2 && kinds.allSatisfy { $0 == .image }
        case .findSimilarImages: (2...36).contains(kinds.count) && kinds.allSatisfy { $0 == .image }
        case .imageContactSheet: kinds.count >= 2 && kinds.count <= 36 && kinds.allSatisfy { $0 == .image }
        case .renameFile: kinds.count == 1
        case .copyFiles, .moveFiles:
            kinds.count >= 2 && kinds.count <= 33 && kinds.last == .folder && kinds.dropLast().allSatisfy { $0 != .folder }
        case .createFolder: kinds.count == 1 && kinds[0] == .folder
        case .findDuplicates:
            kinds.count >= 2 && kinds.count <= 200 && kinds.allSatisfy { $0 != .folder }
        case .organizeByType, .organizeByDate, .organizeByModulePattern:
            !kinds.isEmpty && kinds.count <= 200 && kinds.allSatisfy { $0 != .folder }
        case .organizeDownloads, .findRecent: kinds.count == 1 && kinds[0] == .folder
        case .findByName: (1...200).contains(kinds.count) && (kinds.allSatisfy { $0 == .folder } || kinds.allSatisfy { $0 != .folder })
        case .batchRename, .createArchive: !kinds.isEmpty
        case .inspectArchive, .extractZip: kinds.count == 1 && kinds[0] == .other
        case .extractAudio, .inspectMedia, .thumbnailVideo, .trimVideo, .extractMediaClip, .resizeVideo, .transcodeVideo, .compressVideo: kinds.count == 1 && kinds[0] == .video
        case .transcribeAudio, .generateSubtitles, .convertAudio: kinds.count == 1 && kinds[0] == .audio
        case .summarizeText, .rewriteText, .proofreadText, .translateText, .keyPointsText, .actionItemsText, .toMarkdownText, .explainText:
            kinds.count == 1 && kinds[0] == .text
        case .compareText: kinds.count == 2 && kinds.allSatisfy { $0 == .text }
        case .inspectData, .dataStatistics: kinds.count == 1 && isTable(kinds[0])
        case .importXLSX: kinds.count == 1 && kinds[0] == .table
        case .mergeData: kinds.count >= 2 && kinds.count <= 16 && kinds.allSatisfy(isTable)
        case .deduplicateData: (1...16).contains(kinds.count) && kinds.allSatisfy(isTable)
        case .sortData, .filterData, .selectColumns, .renameColumns, .reorderColumns, .normalizeData:
            kinds.count == 1 && isTable(kinds[0])
        case .csvToJSON: kinds.count == 1 && kinds[0] == .csv
        case .jsonToCSV: kinds.count == 1 && kinds[0] == .table
        case .compareData: kinds.count == 2 && kinds.allSatisfy(isTable)
        case .fetchURL: (1...8).contains(kinds.count) && kinds.allSatisfy { $0 == .url }
        case .extractWebLinks, .researchOpenSources: kinds.count == 1 && kinds[0] == .url
        case .ocrImage, .extractStructuredText: (1...8).contains(kinds.count) && kinds.allSatisfy { $0 == .image }
        case .extractImageTable, .extractReceipt: kinds.count == 1 && kinds[0] == .image
        case .explainCode, .proposePatch: kinds.count == 1 && (kinds[0] == .text || kinds[0] == .patch)
        case .formatJSON: kinds.count == 1 && kinds[0] == .table
        }
    }

    private static func isTable(_ kind: ArtifactKind) -> Bool { kind == .csv || kind == .table }

    private static func typedArguments(_ wire: WireArguments?, for operation: ToolOperation, request: String) -> ToolArguments? {
        switch operation {
        case .mergePDFs, .combineMixedPDFInputs, .removeBlankPDFPages, .splitPDF, .extractPDFText, .ocrPDFText, .inspectPDF, .imagesToPDF, .inspectImage, .smartCropImage, .removeImageMetadata, .removeImageBackground, .compareImages, .findSimilarImages, .imageContactSheet, .createArchive, .inspectArchive, .extractZip, .extractAudio, .transcribeAudio, .generateSubtitles, .inspectMedia, .transcodeVideo,
             .ocrImage, .extractImageTable, .extractReceipt, .extractStructuredText,
             .copyFiles, .moveFiles, .findDuplicates, .organizeByType, .organizeByDate, .organizeByModulePattern, .organizeDownloads, .convertAudio:
            return ToolArguments.none
        case .findRecent, .findByName:
            return .textPrompt(request)
        case .inspectData, .mergeData, .deduplicateData, .dataStatistics, .csvToJSON, .jsonToCSV, .normalizeData, .compareData, .importXLSX:
            return ToolArguments.none
        case .formatJSON:
            return ToolArguments.none
        case .fetchURL, .extractWebLinks, .researchOpenSources:
            return ToolArguments.none
        case .sortData:
            guard let column = wire?.column?.trimmingCharacters(in: .whitespacesAndNewlines), !column.isEmpty, column.count <= 128 else { return nil }
            return .tableSort(column: column, ascending: wire?.ascending ?? true)
        case .filterData:
            guard let column = wire?.column?.trimmingCharacters(in: .whitespacesAndNewlines), !column.isEmpty, column.count <= 128,
                  let value = wire?.value, value.count <= 1_000 else { return nil }
            return .tableFilter(column: column, value: value)
        case .selectColumns, .reorderColumns:
            guard let columns = wire?.columns, !columns.isEmpty, columns.count <= 500,
                  columns.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 128 }),
                  Set(columns).count == columns.count else { return nil }
            return .tableColumns(columns)
        case .renameColumns:
            guard let from = (wire?.from ?? wire?.column)?.trimmingCharacters(in: .whitespacesAndNewlines), !from.isEmpty, from.count <= 128,
                  let to = (wire?.to ?? wire?.name)?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty, to.count <= 128 else { return nil }
            return .tableRenameColumn(from: from, to: to)
        case .summarizeText, .rewriteText, .proofreadText, .translateText, .keyPointsText, .actionItemsText, .toMarkdownText, .compareText, .explainText, .searchPDFText:
            guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.count <= 2_000 else { return nil }
            return .textPrompt(request)
        case .explainCode, .proposePatch:
            guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.count <= 2_000 else { return nil }
            return .textPrompt(request)
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
        case .resizeImage, .batchResizeImages:
            guard let width = wire?.width, (1...20_000).contains(width) else { return nil }
            return .imageResize(width: width)
        case .convertImage, .batchConvertImages:
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
        case .trimVideo, .extractMediaClip:
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
        case .mergePDFs, .combineMixedPDFInputs, .removePDFPages, .removeBlankPDFPages, .splitPDF, .extractPDFPages, .reorderPDFPages, .rotatePDFPages, .imagesToPDF, .compressPDF: [.pdf]
        case .extractPDFText, .ocrPDFText: Array(repeating: .text, count: inputKinds.count)
        case .inspectPDF, .searchPDFText, .inspectImage, .inspectArchive: [.text]
        case .resizeImage, .convertImage, .rotateImage, .cropImage, .smartCropImage, .compressImage, .removeImageMetadata, .removeImageBackground, .imageContactSheet: [.image]
        case .batchResizeImages, .batchConvertImages: Array(repeating: .image, count: inputKinds.count)
        case .compareImages, .findSimilarImages: [.text]
        case .renameFile, .batchRename: inputKinds
        case .copyFiles, .moveFiles: Array(inputKinds.dropLast())
        case .createFolder, .organizeByType, .organizeByDate, .organizeByModulePattern, .organizeDownloads: [.folder]
        case .findDuplicates, .findRecent, .findByName: [.text]
        case .createArchive: [.other]
        case .extractZip: [.folder]
        case .extractAudio, .convertAudio: [.audio]
        case .transcribeAudio: [.text]
        case .generateSubtitles: [.text, .text]
        case .inspectMedia: [.text]
        case .summarizeText, .rewriteText, .proofreadText, .translateText, .keyPointsText, .actionItemsText, .toMarkdownText, .compareText, .explainText: [.text]
        case .inspectData, .dataStatistics, .compareData: [.text]
        case .mergeData, .deduplicateData, .sortData, .filterData, .selectColumns, .renameColumns, .reorderColumns, .normalizeData: [.csv]
        case .csvToJSON: [.table]
        case .importXLSX: [.csv]
        case .jsonToCSV: [.csv]
        case .fetchURL: Array(repeating: .text, count: inputKinds.count)
        case .extractWebLinks, .researchOpenSources: [.text]
        case .ocrImage, .extractStructuredText: Array(repeating: .text, count: inputKinds.count)
        case .extractImageTable: [.csv, .text]
        case .extractReceipt: [.table]
        case .explainCode: [.text]
        case .proposePatch: [.patch, .text]
        case .formatJSON: [.table]
        case .thumbnailVideo: [.image]
        case .trimVideo, .extractMediaClip, .resizeVideo, .transcodeVideo, .compressVideo: [.video]
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
        let column: String?
        let value: String?
        let ascending: Bool?
        let columns: [String]?
        let from: String?
        let to: String?
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
