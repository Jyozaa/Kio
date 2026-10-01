import Foundation
import UniformTypeIdentifiers

public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case pdf, image, audio, video, text, csv, table, url, patch, folder, other
}

public enum AgentID: String, Codable, CaseIterable, Sendable, Identifiable {
    case kio, pip, pixel, zip, echo, clerk, courier, scribe, table, lens, scout, patch

    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
    public var colorHex: UInt {
        switch self {
        case .kio: 0xF4EBDD
        case .pip: 0x93AFC8
        case .pixel: 0xA9CDBD
        case .zip: 0xE5A06C
        case .echo: 0xB9A4D5
        case .clerk: 0xD9A0A8
        case .courier: 0xE88979
        case .scribe: 0xC3B4DE
        case .table: 0xD7C477
        case .lens: 0x77C4D2
        case .scout: 0x6FB5AA
        case .patch: 0x8793A6
        }
    }

    public var roleDescription: String {
        switch self {
        case .kio: "Task coordinator"
        case .pip: "PDF specialist"
        case .pixel: "Image specialist"
        case .zip: "Archive specialist"
        case .echo: "Audio and video specialist"
        case .clerk: "File organization specialist"
        case .courier: "Phone and file transfer specialist"
        case .scribe: "Document and text specialist"
        case .table: "CSV and data specialist"
        case .lens: "OCR and visual interpretation specialist"
        case .scout: "Web and public research specialist"
        case .patch: "Bounded text transformation specialist"
        }
    }
}

public struct ArtifactRef: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let displayName: String
    public let kind: ArtifactKind
    public let fileURL: URL
    public let sizeBytes: Int64
    public let createdAt: Date
    public let parentID: UUID?
    public let verificationNote: String?

    public init(id: UUID = UUID(), displayName: String, kind: ArtifactKind, fileURL: URL, sizeBytes: Int64, createdAt: Date = .now, parentID: UUID? = nil, verificationNote: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.fileURL = fileURL
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.parentID = parentID
        self.verificationNote = verificationNote
    }

    public static func inspect(_ url: URL, parentID: UUID? = nil) throws -> ArtifactRef {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentTypeKey])
        let type = values.contentType
        let kind: ArtifactKind
        if values.isDirectory == true { kind = .folder }
        else if type?.conforms(to: .pdf) == true { kind = .pdf }
        else if type?.conforms(to: .image) == true { kind = .image }
        else if type?.conforms(to: .audio) == true { kind = .audio }
        else if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { kind = .video }
        else if ["kio-url", "kio-query"].contains(url.pathExtension.lowercased()) { kind = .url }
        else if ["patch", "srt", "vtt"].contains(url.pathExtension.lowercased()) { kind = url.pathExtension.lowercased() == "patch" ? .patch : .text }
        else if ["csv", "tsv"].contains(url.pathExtension.lowercased()) { kind = .csv }
        else if ["json", "xlsx"].contains(url.pathExtension.lowercased()) { kind = .table }
        else if ["txt", "md", "markdown", "swift", "py", "js", "jsx", "ts", "tsx", "rs", "go", "java", "c", "h", "cc", "cpp", "cs", "rb", "php", "sh", "html", "css", "xml", "yaml", "yml", "toml", "sql", "kt", "kts", "dart", "vue", "svelte"].contains(url.pathExtension.lowercased()) { kind = .text }
        else if type?.conforms(to: .text) == true { kind = .text }
        else { kind = .other }
        return ArtifactRef(displayName: url.lastPathComponent, kind: kind, fileURL: url, sizeBytes: Int64(values.fileSize ?? 0), parentID: parentID)
    }

    public var isAvailableLocally: Bool {
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        return (try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])) != nil
    }

    public func refreshedFromDisk() -> ArtifactRef? {
        guard isAvailableLocally, let current = try? Self.inspect(fileURL, parentID: parentID) else { return nil }
        guard current.kind == kind else { return nil }
        return ArtifactRef(id: id, displayName: current.displayName, kind: current.kind, fileURL: current.fileURL,
                           sizeBytes: current.sizeBytes, createdAt: createdAt, parentID: parentID,
                           verificationNote: verificationNote)
    }

    /// Safe metadata used to construct planner context; the local path is excluded.
    public var plannerSummary: PlannerArtifact {
        PlannerArtifact(id: id, name: displayName, kind: kind, sizeBytes: sizeBytes)
    }

    public func withVerificationNote(_ note: String?) -> ArtifactRef {
        ArtifactRef(id: id, displayName: displayName, kind: kind, fileURL: fileURL, sizeBytes: sizeBytes,
                    createdAt: createdAt, parentID: parentID, verificationNote: note)
    }
}

public struct PlannerArtifact: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let kind: ArtifactKind
    public let sizeBytes: Int64
}

public enum ToolOperation: String, Codable, CaseIterable, Sendable {
    case mergePDFs = "pdf.merge"
    case removePDFPages = "pdf.removePages"
    case removeBlankPDFPages = "pdf.removeBlankPages"
    case splitPDF = "pdf.split"
    case extractPDFPages = "pdf.extractPages"
    case reorderPDFPages = "pdf.reorderPages"
    case rotatePDFPages = "pdf.rotatePages"
    case extractPDFText = "pdf.extractText"
    case ocrPDFText = "pdf.ocrText"
    case inspectPDF = "pdf.inspect"
    case searchPDFText = "pdf.search"
    case combineMixedPDFInputs = "pdf.combineMixedInputs"
    case imagesToPDF = "image.toPDF"
    case resizeImage = "image.resize"
    case batchResizeImages = "image.batchResize"
    case convertImage = "image.convert"
    case batchConvertImages = "image.batchConvert"
    case compareImages = "image.compare"
    case findSimilarImages = "image.findSimilar"
    case removeImageBackground = "image.removeBackground"
    case rotateImage = "image.rotate"
    case inspectImage = "image.inspect"
    case cropImage = "image.crop"
    case smartCropImage = "image.smartCrop"
    case compressImage = "image.compress"
    case removeImageMetadata = "image.removeMetadata"
    case imageContactSheet = "image.contactSheet"
    case renameFile = "file.rename"
    case batchRename = "file.batchRename"
    case copyFiles = "file.copy"
    case moveFiles = "file.move"
    case createFolder = "file.createFolder"
    case findDuplicates = "file.findDuplicates"
    case findRecent = "file.findRecent"
    case findByName = "file.findByName"
    case organizeByType = "file.organizeByType"
    case organizeByDate = "file.organizeByDate"
    case organizeByModulePattern = "file.organizeByModulePattern"
    case organizeDownloads = "file.organizeDownloads"
    case createArchive = "archive.createZip"
    case inspectArchive = "archive.inspect"
    case extractZip = "archive.extractZip"
    case compressPDF = "pdf.compress"
    case extractAudio = "media.extractAudio"
    case transcribeAudio = "audio.transcribe"
    case generateSubtitles = "media.generateSubtitles"
    case extractMediaClip = "media.extractClip"
    case convertAudio = "audio.convert"
    case inspectMedia = "media.inspect"
    case thumbnailVideo = "media.thumbnail"
    case trimVideo = "media.trim"
    case resizeVideo = "media.resizeVideo"
    case transcodeVideo = "media.transcode"
    case compressVideo = "media.compressVideo"
    case summarizeText = "text.summarize"
    case rewriteText = "text.rewrite"
    case proofreadText = "text.proofread"
    case translateText = "text.translate"
    case keyPointsText = "text.keyPoints"
    case actionItemsText = "text.actionItems"
    case toMarkdownText = "text.toMarkdown"
    case compareText = "text.compare"
    case explainText = "text.explain"
    case inspectData = "data.inspect"
    case mergeData = "data.merge"
    case deduplicateData = "data.deduplicate"
    case sortData = "data.sort"
    case filterData = "data.filter"
    case selectColumns = "data.selectColumns"
    case renameColumns = "data.renameColumns"
    case reorderColumns = "data.reorderColumns"
    case dataStatistics = "data.statistics"
    case csvToJSON = "data.csvToJSON"
    case jsonToCSV = "data.jsonToCSV"
    case normalizeData = "data.normalize"
    case compareData = "data.compare"
    case importXLSX = "data.importXLSX"
    case fetchURL = "web.fetchReadableText"
    case extractWebLinks = "web.extractLinks"
    case researchOpenSources = "web.researchOpenSources"
    case ocrImage = "visual.ocr"
    case extractImageTable = "visual.extractTable"
    case extractReceipt = "visual.extractReceipt"
    case extractStructuredText = "visual.extractStructuredText"
    case explainCode = "code.explain"
    case proposePatch = "code.proposePatch"
    case formatJSON = "data.formatJSON"
}

public enum StepSource: Codable, Sendable, Hashable {
    case artifacts([UUID])
    case previousStep(UUID)
}

public enum ToolArguments: Codable, Sendable, Hashable {
    case none
    case imageResize(width: Int)
    case imageConvert(format: String)
    case imageRotation(degrees: Int)
    case imageCrop(x: Int, y: Int, width: Int, height: Int)
    case imageCompression(maxBytes: Int64?)
    case folderName(name: String)
    case mediaThumbnail(timeMilliseconds: Int64)
    case mediaTrim(startMilliseconds: Int64, durationMilliseconds: Int64)
    case mediaResize(width: Int)
    case mediaCompression(maxBytes: Int64?)
    case exactRename(name: String)
    case rename(prefix: String)
    case removePages(indices: [Int])
    case pageOrder(indices: [Int])
    case pdfRotation(indices: [Int], degrees: Int)
    case pdfCompression(maxBytes: Int64?)
    case textPrompt(String)
    case tableSort(column: String, ascending: Bool)
    case tableFilter(column: String, value: String)
    case tableColumns([String])
    case tableRenameColumn(from: String, to: String)
}

public struct TaskStep: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let operation: ToolOperation
    public let source: StepSource
    public let arguments: ToolArguments

    public init(id: UUID = UUID(), operation: ToolOperation, source: StepSource, arguments: ToolArguments = .none) {
        self.id = id
        self.operation = operation
        self.source = source
        self.arguments = arguments
    }

    public var owner: AgentID { operation.owner }
}

public extension ToolOperation {
    var owner: AgentID {
        switch self {
        case .mergePDFs, .removePDFPages, .removeBlankPDFPages, .splitPDF, .extractPDFPages, .reorderPDFPages, .rotatePDFPages, .extractPDFText, .ocrPDFText, .inspectPDF, .searchPDFText, .combineMixedPDFInputs, .imagesToPDF: .pip
        case .ocrImage, .extractImageTable, .extractReceipt, .extractStructuredText: .lens
        case .explainCode, .proposePatch, .formatJSON: .patch
        case .resizeImage, .batchResizeImages, .convertImage, .batchConvertImages, .compareImages, .findSimilarImages, .removeImageBackground, .rotateImage, .inspectImage, .cropImage, .smartCropImage, .compressImage, .removeImageMetadata, .imageContactSheet: .pixel
        case .renameFile, .batchRename, .copyFiles, .moveFiles, .createFolder, .findDuplicates, .findRecent, .findByName,
             .organizeByType, .organizeByDate, .organizeByModulePattern, .organizeDownloads: .clerk
        case .createArchive, .inspectArchive, .extractZip, .compressPDF: .zip
        case .extractAudio, .transcribeAudio, .generateSubtitles, .extractMediaClip, .convertAudio, .inspectMedia, .thumbnailVideo, .trimVideo, .resizeVideo, .transcodeVideo, .compressVideo: .echo
        case .fetchURL, .extractWebLinks, .researchOpenSources: .scout
        case .summarizeText, .rewriteText, .proofreadText, .translateText, .keyPointsText, .actionItemsText, .toMarkdownText, .compareText, .explainText: .scribe
        case .inspectData, .mergeData, .deduplicateData, .sortData, .filterData, .selectColumns, .renameColumns, .reorderColumns,
             .dataStatistics, .csvToJSON, .jsonToCSV, .normalizeData, .compareData, .importXLSX: .table
        }
    }
}

public struct TaskPlan: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let request: String
    public let steps: [TaskStep]
    public let clarification: String?

    public init(id: UUID = UUID(), request: String, steps: [TaskStep], clarification: String? = nil) {
        self.id = id
        self.request = request
        self.steps = steps
        self.clarification = clarification
    }
}

/// Keeps a plan's original inputs stable while making outputs from completed steps addressable.
public struct PlanArtifactSnapshot: Sendable {
    private let originals: [UUID: ArtifactRef]
    private var outputsByStep: [UUID: [ArtifactRef]] = [:]

    public init(originals: [ArtifactRef]) {
        self.originals = Dictionary(originals.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
    }

    public mutating func resolve(_ step: TaskStep) throws -> [ArtifactRef] {
        switch step.source {
        case .artifacts(let ids):
            guard !ids.isEmpty, ids.allSatisfy({ originals[$0] != nil }) else {
                throw KioFailure.invalidInput("One of the selected files is no longer available. Add it again and retry.")
            }
            return ids.compactMap { originals[$0] }
        case .previousStep(let id):
            guard let outputs = outputsByStep[id], !outputs.isEmpty else {
                throw KioFailure.invalidInput("A previous operation did not produce an output.")
            }
            return outputs
        }
    }

    public mutating func record(_ outputs: [ArtifactRef], for step: TaskStep) {
        outputsByStep[step.id] = outputs
    }
}

public enum TaskExecutionStatus: String, Codable, Sendable {
    case planning, running, completed, waitingForUser, failed, cancelled
}

/// Bounded at-most-once ledger for remote request IDs, including relay redeliveries.
public struct TaskDeduplicationLedger: Sendable, Equatable {
    private var orderedIDs: [String]
    public let maximumEntries: Int

    public init(knownIDs: [String] = [], maximumEntries: Int = 500) {
        self.maximumEntries = max(1, maximumEntries)
        self.orderedIDs = Array(knownIDs.suffix(max(1, maximumEntries)))
    }

    @discardableResult
    public mutating func insertIfNew(_ id: String) -> Bool {
        guard !orderedIDs.contains(id) else { return false }
        orderedIDs.append(id)
        if orderedIDs.count > maximumEntries { orderedIDs.removeFirst(orderedIDs.count - maximumEntries) }
        return true
    }

    public var entries: [String] { orderedIDs }
}

public struct TaskExecutionState: Sendable, Equatable {
    public let taskID: UUID
    public let plan: TaskPlan?
    public let currentStepIndex: Int?
    public let currentOperation: ToolOperation?
    public let activeAgent: AgentID
    public let status: TaskExecutionStatus
    public let statusText: String
    public let completedStepCount: Int
    public let totalStepCount: Int
    public let latestOutput: ArtifactRef?
    public let failureMessage: String?

    public init(taskID: UUID, plan: TaskPlan?, currentStepIndex: Int? = nil, currentOperation: ToolOperation? = nil,
                activeAgent: AgentID = .kio, status: TaskExecutionStatus, statusText: String,
                completedStepCount: Int = 0, totalStepCount: Int = 0, latestOutput: ArtifactRef? = nil,
                failureMessage: String? = nil) {
        self.taskID = taskID
        self.plan = plan
        self.currentStepIndex = currentStepIndex
        self.currentOperation = currentOperation
        self.activeAgent = activeAgent
        self.status = status
        self.statusText = statusText
        self.completedStepCount = completedStepCount
        self.totalStepCount = totalStepCount
        self.latestOutput = latestOutput
        self.failureMessage = failureMessage
    }
}

public enum NotchInteractionReason: Hashable, Sendable {
    case pointer, composing, attachments, dragging, pinned, working, resultInteraction, menuOrPopover
}

/// Centralizes the reasons the expanded notch must remain available for interaction.
public struct NotchInteractionState: Sendable, Equatable {
    private var activeReasons = Set<NotchInteractionReason>()

    public init() {}

    public mutating func set(_ reason: NotchInteractionReason, active: Bool) {
        if active { activeReasons.insert(reason) }
        else { activeReasons.remove(reason) }
    }

    public var shouldRemainExpanded: Bool { !activeReasons.isEmpty }
    public func isActive(_ reason: NotchInteractionReason) -> Bool { activeReasons.contains(reason) }
}

public enum TaskEvent: Sendable, Equatable, Identifiable {
    case status(id: UUID, agent: AgentID, message: String)
    case completed(id: UUID, artifact: ArtifactRef)
    case failure(id: UUID, message: String)

    public var id: UUID {
        switch self {
        case .status(let id, _, _), .completed(let id, _), .failure(let id, _): id
        }
    }
}

public enum KioFailure: Error, LocalizedError, Sendable {
    case unsupported(String)
    case invalidInput(String)
    case processing(String)
    case verification(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message), .invalidInput(let message), .processing(let message), .verification(let message): message
        }
    }
}
