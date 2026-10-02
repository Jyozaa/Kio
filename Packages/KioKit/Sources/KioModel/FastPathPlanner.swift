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
        let inputs = artifacts.isEmpty ? context.activeOutput.map { [$0] } ?? [] : artifacts
        if SemanticIntentParser.explicitlyNegatesAction(request) {
            return TaskPlan(request: request, steps: [], clarification: "Understood. I won't perform that operation. What would you like me to do instead?")
        }
        switch SemanticIntentParser.parse(request, artifacts: inputs) {
        case .clarify(let message):
            return TaskPlan(request: request, steps: [], clarification: message)
        case .resolved(let intent, let confidence) where confidence >= 0.9:
            if let compiled = CapabilityCompiler.compile(intent, request: request, artifacts: inputs) { return compiled }
            if intent.domain == .table, intent.sourceFormat == nil,
               inputs.count == 1, inputs[0].kind == .image { break }
            if inputs.isEmpty {
                return TaskPlan(request: request, steps: [], clarification: "Add the file or public URL you want Kio to convert, then try again.")
            } else {
                return TaskPlan(request: request, steps: [], clarification: "I understood the requested output format, but it isn't supported for these selected files. Check the file types and destination format, then try again.")
            }
        case .resolved:
            return TaskPlan(request: request, steps: [], clarification: "I couldn't determine the requested destination format safely. Which format should the output use?")
        case .noMatch:
            break
        }
        let words = Self.words(in: request)
        let ids = inputs.map(\.id)
        let sizeTarget = SemanticValueParser.targetSizeBytes(in: request) ?? Self.byteLimit(in: request)

        if inputs.count == 1, let query = inputs.first,
           query.kind == .url, query.fileURL.pathExtension.lowercased() == "kio-query" {
            let search = TaskStep(operation: .researchOpenSources, source: .artifacts([query.id]))
            if words.contains("summarize") || words.contains("summarise") || words.contains("summary") {
                let summarize = TaskStep(operation: .summarizeText, source: .previousStep(search.id), arguments: .textPrompt(request))
                return TaskPlan(request: request, steps: [search, summarize])
            }
            return TaskPlan(request: request, steps: [search])
        }

        let mediaInputs = inputs.filter { $0.kind == .url && $0.fileURL.pathExtension.lowercased() != "kio-query" || $0.fileURL.pathExtension.lowercased() == "kio-reel-info" }
        if let mediaPlan = ReelRequestRouter.plan(request: request, artifacts: mediaInputs) { return mediaPlan }

        if let json = inputs.first(where: { $0.kind == .table && $0.fileURL.pathExtension.lowercased() == "json" }),
           words.contains("format") || words.contains("pretty") || words.contains("indent") {
            return TaskPlan(request: request, steps: [TaskStep(operation: .formatJSON, source: .artifacts([json.id]))])
        }

        let codeInputs = inputs.filter { $0.kind == .text && Self.codeExtensions.contains($0.fileURL.pathExtension.lowercased()) }
        if codeInputs.count == 1,
           Self.requestsCodeEdit(words),
           words.contains("code") || words.contains("function") || words.contains("bug") || words.contains("patch") || words.contains("swift") || words.contains("python") {
            return TaskPlan(request: request, steps: [TaskStep(operation: .proposePatch, source: .artifacts([codeInputs[0].id]), arguments: .textPrompt(request))])
        }
        if let code = codeInputs.first, words.contains("explain"),
           words.contains("code") || words.contains("function") || words.contains("file") {
            return TaskPlan(request: request, steps: [TaskStep(operation: .explainCode, source: .artifacts([code.id]), arguments: .textPrompt(request))])
        }

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

        let comparisonImages = inputs.filter { $0.kind == .image }
        if words.contains("compare"), comparisonImages.count == 2 {
            return TaskPlan(request: request, steps: [TaskStep(operation: .compareImages, source: .artifacts(comparisonImages.map(\.id)))])
        }

        if let textOperation = Self.textOperation(in: words) {
            let textInputs = inputs.filter { $0.kind == .text }
            if textOperation == .compareText {
                if textInputs.count == 2 {
                    return TaskPlan(request: request, steps: [TaskStep(operation: textOperation, source: .artifacts(textInputs.map(\.id)), arguments: .textPrompt(request))])
                }
                let urls = inputs.filter { $0.kind == .url }
                if urls.count == 2 {
                    let fetch = TaskStep(operation: .fetchURL, source: .artifacts(urls.map(\.id)))
                    let comparison = TaskStep(operation: .compareText, source: .previousStep(fetch.id), arguments: .textPrompt(request))
                    return TaskPlan(request: request, steps: [fetch, comparison])
                }
                let pdfs = inputs.filter { $0.kind == .pdf }
                if pdfs.count == 2 {
                    let extraction = TaskStep(
                        operation: (words.contains("scan") || words.contains("scanned") || words.contains("ocr")) ? .ocrPDFText : .extractPDFText,
                        source: .artifacts(pdfs.map(\.id))
                    )
                    let comparison = TaskStep(operation: textOperation, source: .previousStep(extraction.id), arguments: .textPrompt(request))
                    return TaskPlan(request: request, steps: [extraction, comparison])
                }
                return TaskPlan(request: request, steps: [], clarification: "Choose two text, Markdown, or PDF files to compare.")
            }
            if textOperation != .compareText, let text = textInputs.first {
                return TaskPlan(request: request, steps: [TaskStep(operation: textOperation, source: .artifacts([text.id]), arguments: .textPrompt(request))])
            }
            if textInputs.isEmpty, let pdf = inputs.first(where: { $0.kind == .pdf }) {
                let extraction = TaskStep(
                    operation: (words.contains("scan") || words.contains("scanned") || words.contains("ocr")) ? .ocrPDFText : .extractPDFText,
                    source: .artifacts([pdf.id])
                )
                let transform = TaskStep(operation: textOperation, source: .previousStep(extraction.id), arguments: .textPrompt(request))
                return TaskPlan(request: request, steps: [extraction, transform])
            }
        }

        let xlsxInputs = inputs.filter { $0.fileURL.pathExtension.lowercased() == "xlsx" }
        if !xlsxInputs.isEmpty {
            guard xlsxInputs.count == 1 else {
                return TaskPlan(request: request, steps: [], clarification: "Import one XLSX workbook at a time. Kio can then work with its CSV output.")
            }
            let workbook = xlsxInputs[0]
            let imported = TaskStep(operation: .importXLSX, source: .artifacts([workbook.id]))
            let resultSource = StepSource.previousStep(imported.id)
            if words.contains("inspect") || words.contains("analyze") || words.contains("analyse") || words.contains("statistics") || words.contains("stats") || words.contains("average") || words.contains("mean") || words.contains("median") || words.contains("summarize") || words.contains("summary") {
                return TaskPlan(request: request, steps: [imported, TaskStep(operation: .dataStatistics, source: resultSource)])
            }
            if words.contains("deduplicate") || words.contains("duplicates") || (words.contains("remove") && words.contains("duplicate")) {
                return TaskPlan(request: request, steps: [imported, TaskStep(operation: .deduplicateData, source: resultSource)])
            }
            if words.contains("normalize") || words.contains("clean") {
                return TaskPlan(request: request, steps: [imported, TaskStep(operation: .normalizeData, source: resultSource)])
            }
            if words.contains("sort") || words.contains("order") {
                guard let column = Self.tableColumn(in: request) else {
                    return TaskPlan(request: request, steps: [], clarification: "Which column should Table sort by after importing the workbook?")
                }
                let ascending = !(words.contains("descending") || words.contains("desc"))
                return TaskPlan(request: request, steps: [imported, TaskStep(operation: .sortData, source: resultSource, arguments: .tableSort(column: column, ascending: ascending))])
            }
            if words.contains("filter") {
                guard let (column, value) = Self.tableFilter(in: request) else {
                    return TaskPlan(request: request, steps: [], clarification: "Which column and value should Table filter for after importing the workbook?")
                }
                return TaskPlan(request: request, steps: [imported, TaskStep(operation: .filterData, source: resultSource, arguments: .tableFilter(column: column, value: value))])
            }
            return TaskPlan(request: request, steps: [imported])
        }

        let tableInputs = inputs.filter { $0.kind == .csv || $0.kind == .table }
        if !tableInputs.isEmpty {
            let tableIDs = tableInputs.map(\.id)
            if words.contains("compare") || words.contains("comparison") {
                if tableInputs.count == 2 {
                    return TaskPlan(request: request, steps: [TaskStep(operation: .compareData, source: .artifacts(tableIDs))])
                }
                return TaskPlan(request: request, steps: [], clarification: "Choose two CSV, TSV, or JSON tables to compare.")
            }

            var tableSteps: [TaskStep] = []
            var currentSource: StepSource = .artifacts(tableIDs)
            if words.contains("merge"), tableInputs.count >= 2 {
                let merge = TaskStep(operation: .mergeData, source: .artifacts(tableIDs))
                tableSteps.append(merge)
                currentSource = .previousStep(merge.id)
            }
            if words.contains("deduplicate") || words.contains("duplicates") || (words.contains("remove") && words.contains("duplicate")) {
                let deduplicate = TaskStep(operation: .deduplicateData, source: currentSource)
                tableSteps.append(deduplicate)
                currentSource = .previousStep(deduplicate.id)
            }
            if words.contains("average") || words.contains("mean") || words.contains("median") || words.contains("statistics") || words.contains("stats") || words.contains("missing") || words.contains("unique") {
                tableSteps.append(TaskStep(operation: .dataStatistics, source: currentSource))
                return TaskPlan(request: request, steps: tableSteps)
            }
            if words.contains("merge"), tableInputs.count >= 2 { return TaskPlan(request: request, steps: tableSteps) }
            if words.contains("convert"), tableInputs.count == 1 {
                return TaskPlan(request: request, steps: [], clarification: "Should this table become CSV or JSON? State the destination format.")
            }
            if words.contains("normalize"), tableInputs.count == 1 {
                return TaskPlan(request: request, steps: [TaskStep(operation: .normalizeData, source: .artifacts([tableIDs[0]]))])
            }
            if words.contains("sort") || words.contains("order") {
                guard tableInputs.count == 1, let column = Self.tableColumn(in: request) else {
                    return TaskPlan(request: request, steps: [], clarification: "Which column should Table sort by?")
                }
                let ascending = !(words.contains("descending") || words.contains("desc"))
                return TaskPlan(request: request, steps: [TaskStep(operation: .sortData, source: .artifacts([tableIDs[0]]), arguments: .tableSort(column: column, ascending: ascending))])
            }
            if words.contains("filter"), tableInputs.count == 1 {
                guard let (column, value) = Self.tableFilter(in: request) else {
                    return TaskPlan(request: request, steps: [], clarification: "Which column and value should Table filter for?")
                }
                return TaskPlan(request: request, steps: [TaskStep(operation: .filterData, source: .artifacts([tableIDs[0]]), arguments: .tableFilter(column: column, value: value))])
            }
            if words.contains("inspect") || words.contains("analyze") || words.contains("analyse") || words.contains("summary") || words.contains("summarize") || words.contains("summarise") {
                return TaskPlan(request: request, steps: [TaskStep(operation: .inspectData, source: .artifacts([tableIDs[0]]))])
            }
            if !tableSteps.isEmpty { return TaskPlan(request: request, steps: tableSteps) }
        }

        let urlInputs = inputs.filter { $0.kind == .url }
        if !urlInputs.isEmpty {
            let urlIDs = urlInputs.map(\.id)
            if words.contains("compare") || words.contains("comparison") {
                guard urlInputs.count == 2 else {
                    return TaskPlan(request: request, steps: [], clarification: "Choose two public URLs to compare.")
                }
                let fetch = TaskStep(operation: .fetchURL, source: .artifacts(urlIDs))
                let compare = TaskStep(operation: .compareText, source: .previousStep(fetch.id), arguments: .textPrompt(request))
                return TaskPlan(request: request, steps: [fetch, compare])
            }
            if words.contains("link") || words.contains("links") {
                guard urlInputs.count == 1 else { return TaskPlan(request: request, steps: [], clarification: "Choose one URL to extract links from.") }
                return TaskPlan(request: request, steps: [TaskStep(operation: .extractWebLinks, source: .artifacts([urlIDs[0]]))])
            }
            if let operation = Self.textOperation(in: words), urlInputs.count == 1 {
                let fetch = TaskStep(operation: .fetchURL, source: .artifacts([urlIDs[0]]))
                let transform = TaskStep(operation: operation, source: .previousStep(fetch.id), arguments: .textPrompt(request))
                return TaskPlan(request: request, steps: [fetch, transform])
            }
            if urlInputs.count == 1, words.contains("fetch") || words.contains("read") || words.contains("extract") {
                return TaskPlan(request: request, steps: [TaskStep(operation: .fetchURL, source: .artifacts([urlIDs[0]]))])
            }
        }

        let pdfInputs = inputs.filter { $0.kind == .pdf }
        let imageInputs = inputs.filter { $0.kind == .image }
        let mixedDocumentInputs = inputs.filter { $0.kind == .pdf || $0.kind == .image }
        if !pdfInputs.isEmpty, !imageInputs.isEmpty,
           words.contains("pdf") || words.contains("combine") || words.contains("merge") || words.contains("join") {
            guard (2...32).contains(mixedDocumentInputs.count) else {
                return TaskPlan(request: request, steps: [], clarification: "Choose 2 to 32 PDF and image files to combine.")
            }
            var steps = [TaskStep(operation: .combineMixedPDFInputs, source: .artifacts(mixedDocumentInputs.map(\.id)))]
            if let sizeTarget, let createPDF = steps.last {
                steps.append(TaskStep(operation: .compressPDF, source: .previousStep(createPDF.id), arguments: .pdfCompression(maxBytes: sizeTarget)))
            }
            return TaskPlan(request: request, steps: steps)
        }
        if words.contains("merge"), pdfInputs.count >= 2 {
            var steps = [TaskStep(operation: .mergePDFs, source: .artifacts(pdfInputs.map(\.id)))]
            if let sizeTarget, let merge = steps.last {
                steps.append(TaskStep(operation: .compressPDF, source: .previousStep(merge.id), arguments: .pdfCompression(maxBytes: sizeTarget)))
            }
            return TaskPlan(request: request, steps: steps)
        }
        if words.contains("split"), let pdf = inputs.first(where: { $0.kind == .pdf }) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .splitPDF, source: .artifacts([pdf.id]))])
        }
        if let pdf = inputs.first(where: { $0.kind == .pdf }),
           words.contains("mention") || words.contains("search") || (words.contains("find") && words.contains("pdf")) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .searchPDFText, source: .artifacts([pdf.id]), arguments: .textPrompt(request))])
        }
        if (words.contains("extract") || Self.requestsPageExtraction(in: request)), (words.contains("page") || words.contains("pages")),
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
        if Self.requestsPageRemoval(in: request), (words.contains("page") || words.contains("pages")), let pdf = inputs.first(where: { $0.kind == .pdf }),
           let range = Self.pageRange(in: request) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .removePDFPages, source: .artifacts([pdf.id]), arguments: .removePages(indices: range))])
        }
        if words.contains("pdf"), !imageInputs.isEmpty {
            var steps = [TaskStep(operation: .imagesToPDF, source: .artifacts(imageInputs.map(\.id)))]
            if let sizeTarget, let createPDF = steps.last {
                steps.append(TaskStep(operation: .compressPDF, source: .previousStep(createPDF.id), arguments: .pdfCompression(maxBytes: sizeTarget)))
            }
            return TaskPlan(request: request, steps: steps)
        }
        if let pdf = inputs.first(where: { $0.kind == .pdf }),
           sizeTarget != nil || words.contains("compress") || words.contains("smaller") {
            return TaskPlan(request: request, steps: [TaskStep(operation: .compressPDF, source: .artifacts([pdf.id]), arguments: .pdfCompression(maxBytes: sizeTarget))])
        }
        let selectedImages = inputs.filter { $0.kind == .image }
        if let image = selectedImages.first,
           words.contains("crop"), ["smart", "auto", "automatic", "subject", "focus"].contains(where: words.contains) {
            return TaskPlan(request: request, steps: [TaskStep(operation: .smartCropImage, source: .artifacts([image.id]))])
        }
        if words.contains("resize"), !selectedImages.isEmpty,
           let width = Self.imageWidth(in: request), (1...20_000).contains(width) {
            let operation: ToolOperation = selectedImages.count > 1 ? .batchResizeImages : .resizeImage
            return TaskPlan(request: request, steps: [TaskStep(operation: operation, source: .artifacts(selectedImages.map(\.id)), arguments: .imageResize(width: width))])
        }
        let visualInputs = selectedImages
        if words.contains("compare"), !visualInputs.isEmpty {
            guard visualInputs.count == 2 else { return TaskPlan(request: request, steps: [], clarification: "Choose exactly two images to compare.") }
            return TaskPlan(request: request, steps: [TaskStep(operation: .compareImages, source: .artifacts(visualInputs.map(\.id)))])
        }
        if words.contains("similar"), !visualInputs.isEmpty {
            guard (2...36).contains(visualInputs.count) else { return TaskPlan(request: request, steps: [], clarification: "Choose 2 to 36 images to look for approximate visual matches.") }
            return TaskPlan(request: request, steps: [TaskStep(operation: .findSimilarImages, source: .artifacts(visualInputs.map(\.id)))])
        }
        if words.contains("background"), words.contains("remove"), !visualInputs.isEmpty {
            guard (1...12).contains(visualInputs.count) else { return TaskPlan(request: request, steps: [], clarification: "Pixel can remove backgrounds from 1 to 12 images per batch.") }
            let operation: ToolOperation = visualInputs.count == 1 ? .removeImageBackground : .batchRemoveImageBackground
            return TaskPlan(request: request, steps: [TaskStep(operation: operation, source: .artifacts(visualInputs.map(\.id)))])
        }
        if !visualInputs.isEmpty {
            if words.contains("receipt") || words.contains("invoice") {
                guard visualInputs.count == 1 else { return TaskPlan(request: request, steps: [], clarification: "Process one receipt or invoice image at a time.") }
                return TaskPlan(request: request, steps: [TaskStep(operation: .extractReceipt, source: .artifacts([visualInputs[0].id]))])
            }
            if words.contains("table") || words.contains("spreadsheet") || words.contains("rows") || words.contains("columns") {
                guard visualInputs.count == 1 else { return TaskPlan(request: request, steps: [], clarification: "Extract one pictured table at a time.") }
                return TaskPlan(request: request, steps: [TaskStep(operation: .extractImageTable, source: .artifacts([visualInputs[0].id]))])
            }
            if ["ocr", "text", "read", "extract", "transcribe"].contains(where: words.contains) {
                return TaskPlan(request: request, steps: [TaskStep(operation: .ocrImage, source: .artifacts(visualInputs.prefix(8).map(\.id)))])
            }
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
        if inputs.count == 1, let name = SemanticValueParser.renameTarget(in: request) {
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
        if words.contains("organize"), (words.contains("download") || words.contains("downloads")), let folder = inputs.first(where: { $0.kind == .folder }) {
            guard folder.fileURL.lastPathComponent.lowercased() == "downloads" else {
                return TaskPlan(request: request, steps: [], clarification: "Choose the Downloads folder itself so Clerk can make an organized copy of its files.")
            }
            return TaskPlan(request: request, steps: [TaskStep(operation: .organizeDownloads, source: .artifacts([folder.id]))])
        }
        if words.contains("organize"), (words.contains("download") || words.contains("downloads")) {
            return TaskPlan(request: request, steps: [], clarification: "Choose the Downloads folder first. Clerk will organize verified copies and keep the originals in place.")
        }
        if words.contains("find"), words.contains("recent") {
            guard let folder = inputs.first(where: { $0.kind == .folder }) else {
                return TaskPlan(request: request, steps: [], clarification: "Choose the folder Clerk should search for recent files.")
            }
            return TaskPlan(request: request, steps: [TaskStep(operation: .findRecent, source: .artifacts([folder.id]), arguments: .textPrompt(request))])
        }
        if words.contains("find"), (words.contains("name") || words.contains("named") || words.contains("filename")) {
            if let folder = inputs.first(where: { $0.kind == .folder }) {
                return TaskPlan(request: request, steps: [TaskStep(operation: .findByName, source: .artifacts([folder.id]), arguments: .textPrompt(request))])
            }
            let files = inputs.filter { $0.kind != .folder }
            if !files.isEmpty {
                return TaskPlan(request: request, steps: [TaskStep(operation: .findByName, source: .artifacts(files.map(\.id)), arguments: .textPrompt(request))])
            }
            return TaskPlan(request: request, steps: [], clarification: "Choose a folder or files for Clerk to search by name.")
        }
        if words.contains("organize"), words.contains("module") {
            let files = inputs.filter { $0.kind != .folder }
            guard !files.isEmpty else {
                return TaskPlan(request: request, steps: [], clarification: "Choose the files Clerk should group by their filename module prefix.")
            }
            let step = TaskStep(operation: .organizeByModulePattern, source: .artifacts(files.map(\.id)))
            return TaskPlan(request: request, steps: [step])
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
            if words.contains("subtitle") || words.contains("subtitles") || words.contains("caption") || words.contains("captions") || words.contains("srt") || words.contains("vtt") {
                let extract = TaskStep(operation: .extractAudio, source: .artifacts([video.id]))
                let subtitles = TaskStep(operation: .generateSubtitles, source: .previousStep(extract.id))
                return TaskPlan(request: request, steps: [extract, subtitles])
            }
            if words.contains("transcribe") || words.contains("transcription") {
                let extract = TaskStep(operation: .extractAudio, source: .artifacts([video.id]))
                let transcript = TaskStep(operation: .transcribeAudio, source: .previousStep(extract.id))
                return TaskPlan(request: request, steps: [extract, transcript])
            }
            if words.contains("inspect") || words.contains("details") || words.contains("info") {
                return TaskPlan(request: request, steps: [TaskStep(operation: .inspectMedia, source: .artifacts([video.id]))])
            }
            if words.contains("thumbnail") || words.contains("frame") {
                let time = Self.videoTimeMilliseconds(in: request) ?? 0
                return TaskPlan(request: request, steps: [TaskStep(operation: .thumbnailVideo, source: .artifacts([video.id]), arguments: .mediaThumbnail(timeMilliseconds: time))])
            }
            if (words.contains("trim") || words.contains("clip") || words.contains("extract")), let range = Self.videoTrimRange(in: request) {
                let operation: ToolOperation = words.contains("clip") || words.contains("extract") ? .extractMediaClip : .trimVideo
                return TaskPlan(request: request, steps: [TaskStep(operation: operation, source: .artifacts([video.id]),
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
        if let audio = inputs.first(where: { $0.kind == .audio }) {
            if words.contains("convert") || words.contains("transcode") {
                return TaskPlan(request: request, steps: [], clarification: "Which audio format should Echo create: MP3, M4A, WAV, or FLAC?")
            }
            if words.contains("subtitle") || words.contains("subtitles") || words.contains("caption") || words.contains("captions") || words.contains("srt") || words.contains("vtt") {
                return TaskPlan(request: request, steps: [TaskStep(operation: .generateSubtitles, source: .artifacts([audio.id]))])
            }
            if words.contains("transcribe") || words.contains("transcription") || words.contains("transcript") {
                return TaskPlan(request: request, steps: [TaskStep(operation: .transcribeAudio, source: .artifacts([audio.id]))])
            }
        }
        let clarification: String
        if inputs.isEmpty { clarification = "Add one or more files, then tell me what you want done." }
        else { clarification = "I don't have a reliable local workflow for that request yet. Try merging, splitting, inspecting, or editing PDF pages; converting or resizing images; renaming files; creating a ZIP; or extracting audio from a video." }
        return TaskPlan(request: request, steps: [], clarification: clarification)
    }

    private static func words(in request: String) -> Set<String> {
        Set(request.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    private static func requestsCodeEdit(_ words: Set<String>) -> Bool {
        let editVerbs: Set<String> = [
            "add", "annotate", "change", "edit", "fix", "implement", "modify", "patch",
            "refactor", "remove", "rename", "replace", "update"
        ]
        return !words.isDisjoint(with: editVerbs)
    }

    private static func textOperation(in words: Set<String>) -> ToolOperation? {
        if words.contains("compare") || words.contains("comparison") { return .compareText }
        if words.contains("translate") || words.contains("translation") { return .translateText }
        if words.contains("proofread") || words.contains("proofreading") || (words.contains("grammar") && words.contains("fix")) { return .proofreadText }
        if words.contains("rewrite") || words.contains("rephrase") { return .rewriteText }
        if words.contains("action") && (words.contains("item") || words.contains("items")) || words.contains("todo") { return .actionItemsText }
        if words.contains("key") && words.contains("points") { return .keyPointsText }
        if words.contains("markdown") { return .toMarkdownText }
        if words.contains("explain") || words.contains("simplify") { return .explainText }
        if words.contains("summarize") || words.contains("summarise") || words.contains("summary") { return .summarizeText }
        return nil
    }

    private static func tableColumn(in request: String) -> String? {
        guard let captures = firstCapture(#"(?i)\bby\s+(?:the\s+)?(?:column\s+)?[\"']?([^\"'\n,.!?]+)"#, in: request),
              let value = captures.last?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.count <= 128 else { return nil }
        return value
            .replacingOccurrences(of: #"(?i)\s+(?:ascending|descending|asc|desc)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+column$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tableFilter(in request: String) -> (String, String)? {
        guard let captures = firstCapture(#"(?i)\bwhere\s+([^=]+?)\s+(?:is|equals?|=)\s+(.+?)(?:[.!?]|$)"#, in: request), captures.count == 2 else { return nil }
        let column = captures[0].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        let value = captures[1].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        guard !column.isEmpty, column.count <= 128, !value.isEmpty, value.count <= 1_000 else { return nil }
        return (column, value)
    }

    private static func supports(_ operation: ToolOperation, kinds: [ArtifactKind]) -> Bool {
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
        case .batchRemoveImageBackground: (1...12).contains(kinds.count) && kinds.allSatisfy { $0 == .image }
        case .batchResizeImages, .batchConvertImages: (1...32).contains(kinds.count) && kinds.allSatisfy { $0 == .image }
        case .compareImages: kinds.count == 2 && kinds.allSatisfy { $0 == .image }
        case .findSimilarImages: (2...36).contains(kinds.count) && kinds.allSatisfy { $0 == .image }
        case .imageContactSheet: kinds.count >= 2 && kinds.count <= 36 && kinds.allSatisfy { $0 == .image }
        case .renameFile: kinds.count == 1
        case .copyFiles, .moveFiles: kinds.count >= 2 && kinds.last == .folder && kinds.dropLast().allSatisfy { $0 != .folder }
        case .createFolder: kinds.count == 1 && kinds[0] == .folder
        case .findDuplicates: kinds.count >= 2 && kinds.count <= 200 && kinds.allSatisfy { $0 != .folder }
        case .organizeByType, .organizeByDate, .organizeByModulePattern: !kinds.isEmpty && kinds.count <= 200 && kinds.allSatisfy { $0 != .folder }
        case .organizeDownloads, .findRecent: kinds.count == 1 && kinds[0] == .folder
        case .findByName: (1...200).contains(kinds.count) && (kinds.allSatisfy { $0 == .folder } || kinds.allSatisfy { $0 != .folder })
        case .batchRename, .createArchive: !kinds.isEmpty
        case .inspectArchive, .extractZip: kinds.count == 1 && kinds[0] == .other
        case .extractAudio, .inspectMedia, .thumbnailVideo, .trimVideo, .extractMediaClip, .resizeVideo, .transcodeVideo, .compressVideo: kinds.count == 1 && kinds[0] == .video
        case .convertAudio: kinds.count == 1 && (kinds[0] == .audio || kinds[0] == .video)
        case .transcribeAudio, .generateSubtitles: kinds.count == 1 && kinds[0] == .audio
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
        case .inspectRemoteMedia: kinds.count == 1 && kinds[0] == .url
        case .downloadRemoteVideo, .downloadRemoteAudio, .downloadRemoteLive,
             .downloadRemoteSubtitles, .downloadRemoteThumbnail:
            kinds.count == 1 && (kinds[0] == .url || kinds[0] == .text)
        case .ocrImage: (1...8).contains(kinds.count) && kinds.allSatisfy { $0 == .image }
        case .extractImageTable, .extractReceipt: kinds.count == 1 && kinds[0] == .image
        case .extractStructuredText: (1...8).contains(kinds.count) && kinds.allSatisfy { $0 == .image }
        case .explainCode, .proposePatch: kinds.count == 1 && (kinds[0] == .text || kinds[0] == .patch)
        case .formatJSON: kinds.count == 1 && kinds[0] == .table
        }
    }

    private static let codeExtensions: Set<String> = ["swift", "py", "js", "jsx", "ts", "tsx", "rs", "go", "java", "c", "h", "cc", "cpp", "cs", "rb", "php", "sh", "html", "css", "xml", "yaml", "yml", "toml", "sql", "kt", "kts", "dart", "vue", "svelte"]

    public static func isCompatible(_ operation: ToolOperation, inputKinds: [ArtifactKind]) -> Bool {
        supports(operation, kinds: inputKinds)
    }

    public static func hasValidArguments(_ arguments: ToolArguments, for operation: ToolOperation) -> Bool {
        validArguments(arguments, for: operation)
    }

    public static func outputKinds(for operation: ToolOperation, inputKinds: [ArtifactKind]) -> [ArtifactKind] {
        resultKinds(for: operation, inputKinds: inputKinds)
    }

    private static func isTable(_ kind: ArtifactKind) -> Bool { kind == .csv || kind == .table }

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
            allowedShape = (previous[0].operation == .mergePDFs || previous[0].operation == .imagesToPDF || previous[0].operation == .combineMixedPDFInputs)
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
        case .mergePDFs, .combineMixedPDFInputs, .removeBlankPDFPages, .splitPDF, .extractPDFText, .ocrPDFText, .inspectPDF, .imagesToPDF, .inspectImage, .smartCropImage, .removeImageMetadata, .removeImageBackground, .batchRemoveImageBackground, .compareImages, .findSimilarImages, .imageContactSheet, .createArchive, .inspectArchive, .extractZip, .extractAudio, .transcribeAudio, .generateSubtitles, .inspectMedia, .inspectRemoteMedia,
             .ocrImage, .extractImageTable, .extractReceipt, .extractStructuredText,
             .findDuplicates, .organizeByType, .organizeByDate, .organizeByModulePattern, .organizeDownloads:
            return arguments == .none
        case .findRecent, .findByName:
            if case .textPrompt(let request) = arguments { return !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.count <= 2_000  } else { return false }
        case .removePDFPages, .extractPDFPages:
            if case .removePages(let indices) = arguments {
                return !indices.isEmpty && indices.allSatisfy { (1...100_000).contains($0) } && Set(indices).count == indices.count
            } else { return false }
        case .reorderPDFPages:
            if case .pageOrder(let indices) = arguments {
                return (1...300).contains(indices.count) && indices.allSatisfy { (1...300).contains($0) } && Set(indices).count == indices.count
            } else { return false }
        case .rotatePDFPages:
            if case .pdfRotation(let indices, let degrees) = arguments {
                return indices.count <= 200 && indices.allSatisfy { (1...100_000).contains($0) } && [90, 180, 270].contains(degrees)
            } else { return false }
        case .resizeImage, .batchResizeImages:
            if case .imageResize(let width) = arguments { return (1...20_000).contains(width)  } else { return false }
        case .convertImage, .batchConvertImages:
            if case .imageConvert(let format) = arguments { return ["png", "jpeg", "jpg", "heic", "tiff", "webp"].contains(format)  } else { return false }
        case .convertAudio:
            if case .audioConvert = arguments { return true  } else { return false }
        case .rotateImage:
            if case .imageRotation(let degrees) = arguments { return [90, 180, 270].contains(degrees)  } else { return false }
        case .cropImage:
            if case .imageCrop(let x, let y, let width, let height) = arguments {
                return (0...20_000).contains(x) && (0...20_000).contains(y) && (1...20_000).contains(width) && (1...20_000).contains(height) && x + width <= 20_000 && y + height <= 20_000
            } else { return false }
        case .compressImage:
            if case .imageCompression(let maxBytes) = arguments { return maxBytes.map { (1...1_000_000_000).contains($0) } ?? true  } else { return false }
        case .thumbnailVideo:
            if case .mediaThumbnail(let time) = arguments { return (0...86_400_000).contains(time)  } else { return false }
        case .trimVideo, .extractMediaClip:
            if case .mediaTrim(let start, let duration) = arguments { return (0...86_400_000).contains(start) && (1...86_400_000).contains(duration) && start + duration <= 86_400_000  } else { return false }
        case .resizeVideo:
            if case .mediaResize(let width) = arguments { return [640, 960, 1280].contains(width)  } else { return false }
        case .transcodeVideo:
            if case .videoConvert = arguments { return true } else { return arguments == .none }
        case .compressVideo:
            if case .mediaCompression(let maxBytes) = arguments { return maxBytes.map { (1...10_000_000_000).contains($0) } ?? true  } else { return false }
        case .renameFile:
            if case .exactRename(let name) = arguments { return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 100  } else { return false }
        case .batchRename:
            if case .rename(let prefix) = arguments { return !prefix.isEmpty && prefix.count <= 64  } else { return false }
        case .copyFiles, .moveFiles:
            return arguments == .none
        case .createFolder:
            if case .folderName(let name) = arguments { return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 100  } else { return false }
        case .compressPDF:
            if case .pdfCompression(let maxBytes) = arguments { return maxBytes.map { $0 > 0 } ?? true  } else { return false }
        case .summarizeText, .rewriteText, .proofreadText, .translateText, .keyPointsText, .actionItemsText, .toMarkdownText, .compareText, .explainText:
            if case .textPrompt(let request) = arguments { return !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.count <= 2_000  } else { return false }
        case .inspectData, .mergeData, .deduplicateData, .dataStatistics, .csvToJSON, .jsonToCSV, .normalizeData, .compareData, .importXLSX:
            return arguments == .none
        case .fetchURL, .extractWebLinks, .researchOpenSources:
            return arguments == .none
        case .downloadRemoteVideo, .downloadRemoteAudio, .downloadRemoteLive,
            .downloadRemoteSubtitles, .downloadRemoteThumbnail:
            if case .remoteMedia(let quality, let format) = arguments {
                let allowedFormats: Set<String> = switch operation {
                case .downloadRemoteAudio: ["mp3", "m4a", "wav", "flac"]
                case .downloadRemoteVideo, .downloadRemoteLive: ["mp4", "webm", "mkv", "mov"]
                case .downloadRemoteSubtitles, .downloadRemoteThumbnail: []
                default: []
                }
                return (quality.map { ["best", "2160p", "1440p", "1080p", "720p", "480p", "360p"].contains($0) } ?? true)
                    && (format.map { allowedFormats.contains($0) } ?? true)
                    && (![.downloadRemoteSubtitles, .downloadRemoteThumbnail].contains(operation) || format == nil)
            } else { return false }
        case .explainCode, .proposePatch:
            if case .textPrompt(let request) = arguments { return !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.count <= 2_000  } else { return false }
        case .searchPDFText:
            if case .textPrompt(let request) = arguments { return !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && request.count <= 2_000  } else { return false }
        case .formatJSON:
            return arguments == .none
        case .sortData:
            if case .tableSort(let column, _) = arguments { return !column.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && column.count <= 128  } else { return false }
        case .filterData:
            if case .tableFilter(let column, let value) = arguments { return !column.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && column.count <= 128 && value.count <= 1_000  } else { return false }
        case .selectColumns, .reorderColumns:
            if case .tableColumns(let columns) = arguments { return !columns.isEmpty && columns.count <= 500 && Set(columns).count == columns.count && columns.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 128 }  } else { return false }
        case .renameColumns:
            if case .tableRenameColumn(let from, let to) = arguments { return !from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && from.count <= 128 && !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && to.count <= 128  } else { return false }
        }
    }
    private static func resultKinds(for operation: ToolOperation, inputKinds: [ArtifactKind]) -> [ArtifactKind] {
        switch operation {
        case .mergePDFs, .combineMixedPDFInputs, .removePDFPages, .removeBlankPDFPages, .splitPDF, .extractPDFPages, .reorderPDFPages, .rotatePDFPages, .imagesToPDF, .compressPDF: [.pdf]
        case .extractPDFText, .ocrPDFText: Array(repeating: .text, count: inputKinds.count)
        case .inspectPDF, .searchPDFText, .inspectImage, .inspectArchive: [.text]
        case .ocrImage, .extractStructuredText: Array(repeating: .text, count: inputKinds.count)
        case .extractImageTable: [.csv, .text]
        case .extractReceipt: [.table]
        case .explainCode: [.text]
        case .proposePatch: [.patch, .text]
        case .formatJSON: [.table]
        case .resizeImage, .convertImage, .rotateImage, .cropImage, .smartCropImage, .compressImage, .removeImageMetadata, .removeImageBackground, .imageContactSheet: [.image]
        case .batchRemoveImageBackground: Array(repeating: .image, count: inputKinds.count)
        case .batchResizeImages, .batchConvertImages: Array(repeating: .image, count: inputKinds.count)
        case .compareImages, .findSimilarImages: [.text]
        case .renameFile, .batchRename: inputKinds
        case .copyFiles, .moveFiles: Array(inputKinds.dropLast())
        case .createFolder, .organizeByType, .organizeByDate, .organizeByModulePattern, .organizeDownloads: [.folder]
        case .findDuplicates, .findRecent, .findByName: [.text]
        case .createArchive: [.other]
        case .extractZip: [.folder]
        case .extractAudio: [.audio]
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
        case .inspectRemoteMedia: [.other]
        case .downloadRemoteVideo, .downloadRemoteLive: [.video]
        case .downloadRemoteAudio: [.audio]
        case .downloadRemoteSubtitles: [.text]
        case .downloadRemoteThumbnail: [.image]
        case .thumbnailVideo: [.image]
        case .trimVideo, .extractMediaClip, .resizeVideo, .transcodeVideo, .compressVideo: [.video]
        case .convertAudio: [.audio]
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
        SemanticValueParser.pageSelection(in: request)
    }

    private static func requestsPageExtraction(in request: String) -> Bool {
        request.range(of: #"(?i)\btake\s+pages?\b"#, options: .regularExpression) != nil
    }

    private static func requestsPageRemoval(in request: String) -> Bool {
        request.range(of: #"(?i)\b(?:remove|delete)\s+pages?\b|\bget\s+rid\s+of\s+pages?\b"#, options: .regularExpression) != nil
    }

    private static func pageOrder(in request: String) -> [Int]? {
        guard let selection = firstCapture(#"(?i)\breorder(?:\s+the)?\s+pages?\s+([\d\s,;and-]+)"#, in: request)?.first else { return nil }
        let order = allCaptures(#"\d+"#, in: selection).compactMap(Int.init)
        guard (1...300).contains(order.count), order.allSatisfy({ (1...300).contains($0) }), Set(order).count == order.count else { return nil }
        return order
    }

    private static func videoTimeMilliseconds(in request: String) -> Int64? {
        SemanticValueParser.videoTime(in: request)
    }

    private static func videoTrimRange(in request: String) -> (Int64, Int64)? {
        guard let value = SemanticValueParser.videoRange(in: request) else { return nil }
        return (value.startMilliseconds, value.durationMilliseconds)
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
