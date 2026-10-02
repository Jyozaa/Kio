import Foundation
import UniformTypeIdentifiers

public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case pdf, image, audio, video, text, csv, table, url, patch, folder, other
}

public enum ArtifactRole: String, Codable, Sendable {
    case userInput, userResult, internalIntermediate
}

public enum AudioTargetFormat: String, Codable, CaseIterable, Sendable {
    case mp3, m4a, wav, flac
}

public enum AgentID: String, Codable, CaseIterable, Sendable, Identifiable {
    case kio, pip, pixel, zip, echo, clerk, courier, scribe, table, lens, scout, patch, reel, cue

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
        case .reel: 0xD58B7C
        case .cue: 0xA8C98D
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
        case .reel: "Public online media acquisition specialist"
        case .cue: "Teleprompter and presentation specialist"
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
    public let role: ArtifactRole

    public init(id: UUID = UUID(), displayName: String, kind: ArtifactKind, fileURL: URL, sizeBytes: Int64, createdAt: Date = .now, parentID: UUID? = nil, verificationNote: String? = nil, role: ArtifactRole? = nil) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.fileURL = fileURL
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.parentID = parentID
        self.verificationNote = verificationNote
        self.role = role ?? (fileURL.pathExtension.lowercased() == "kio-reel-info" ? .internalIntermediate : (parentID == nil ? .userInput : .userResult))
    }

    private enum CodingKeys: String, CodingKey { case id, displayName, kind, fileURL, sizeBytes, createdAt, parentID, verificationNote, role }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let fileURL = try values.decode(URL.self, forKey: .fileURL)
        let parentID = try values.decodeIfPresent(UUID.self, forKey: .parentID)
        let role = try values.decodeIfPresent(ArtifactRole.self, forKey: .role)
            ?? (fileURL.pathExtension.lowercased() == "kio-reel-info" ? .internalIntermediate : (parentID == nil ? .userInput : .userResult))
        self.init(id: try values.decode(UUID.self, forKey: .id),
                  displayName: try values.decode(String.self, forKey: .displayName),
                  kind: try values.decode(ArtifactKind.self, forKey: .kind), fileURL: fileURL,
                  sizeBytes: try values.decode(Int64.self, forKey: .sizeBytes),
                  createdAt: try values.decode(Date.self, forKey: .createdAt), parentID: parentID,
                  verificationNote: try values.decodeIfPresent(String.self, forKey: .verificationNote), role: role)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(kind, forKey: .kind)
        try values.encode(fileURL, forKey: .fileURL)
        try values.encode(sizeBytes, forKey: .sizeBytes)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(parentID, forKey: .parentID)
        try values.encodeIfPresent(verificationNote, forKey: .verificationNote)
        try values.encode(role, forKey: .role)
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
        let role: ArtifactRole = url.pathExtension.lowercased() == "kio-reel-info" ? .internalIntermediate : (parentID == nil ? .userInput : .userResult)
        return ArtifactRef(displayName: url.lastPathComponent, kind: kind, fileURL: url, sizeBytes: Int64(values.fileSize ?? 0), parentID: parentID, role: role)
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
                           verificationNote: verificationNote, role: role)
    }

    /// Safe metadata used to construct planner context; the local path is excluded.
    public var plannerSummary: PlannerArtifact {
        PlannerArtifact(id: id, name: displayName, kind: kind, sizeBytes: sizeBytes)
    }

    public func withVerificationNote(_ note: String?) -> ArtifactRef {
        ArtifactRef(id: id, displayName: displayName, kind: kind, fileURL: fileURL, sizeBytes: sizeBytes,
                    createdAt: createdAt, parentID: parentID, verificationNote: note, role: role)
    }
}

public struct PlannerArtifact: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let kind: ArtifactKind
    public let sizeBytes: Int64
}

public enum TaskInputSurface: String, Codable, Sendable {
    case localComposer, phoneRemote, contextualAction, workflow
}

public struct ProviderContentConsentScope: Sendable, Hashable {
    public let taskID: UUID
    public let providerID: String
    public let sourceArtifactIDs: [UUID]
    public let sourceNames: [String]

    public init(taskID: UUID, providerID: String, sourceArtifactIDs: [UUID], sourceNames: [String] = []) {
        self.taskID = taskID
        self.providerID = providerID
        self.sourceArtifactIDs = Array(Set(sourceArtifactIDs)).sorted { $0.uuidString < $1.uuidString }
        self.sourceNames = Array(Set(sourceNames)).sorted()
    }
}

public enum TaskExecutionContext {
    @TaskLocal public static var contentConsentScope: ProviderContentConsentScope?
}

@MainActor
public final class ProviderContentConsentLedger {
    public static let shared = ProviderContentConsentLedger()
    private var approvedScopes: Set<ProviderContentConsentScope> = []

    public func contains(_ scope: ProviderContentConsentScope) -> Bool { approvedScopes.contains(scope) }
    public func approve(_ scope: ProviderContentConsentScope) { approvedScopes.insert(scope) }
    public func clear(taskID: UUID) { approvedScopes = approvedScopes.filter { $0.taskID != taskID } }
}

/// Immutable request inputs captured at submission time. Separate remote and local
/// submissions cannot be merged by later mutations to the shared composer.
public struct TaskInputSnapshot: Sendable, Equatable {
    public let request: String
    public let artifacts: [ArtifactRef]
    public let surface: TaskInputSurface

    public init(request: String, artifacts: [ArtifactRef], surface: TaskInputSurface) {
        self.request = request
        self.artifacts = artifacts
        self.surface = surface
    }
}

public struct ReelVariant: Codable, Sendable, Equatable, Identifiable {
    public let quality: String
    public let container: String
    public let videoFormatID: String
    public let audioFormatID: String?
    public let videoCodec: String?
    public let audioCodec: String?
    public let needsTranscode: Bool
    public let width: Int?
    public let height: Int?
    public let fps: Double?
    public let bitrate: Double?
    public let videoBitrate: Double?
    public let filesize: Int64?
    public let hasVideo: Bool?
    public let hasAudio: Bool?
    public let language: String?
    public let languagePreference: Double?
    public let formatNote: String?
    public let audioChannels: Int?
    public let abr: Double?
    public let preference: Double?
    public let sourcePreference: Double?
    public let videoPreference: Double?
    public let videoSourcePreference: Double?
    public let sourceContainer: String?
    public let sourceProtocol: String?
    public let sourceBackend: String?

    public var id: String { [quality, container, videoFormatID, audioFormatID ?? ""].joined(separator: ":") }
    public var formatSelector: String { videoFormatID + (audioFormatID.map { "+\($0)" } ?? "") }

    public init(quality: String, container: String, videoFormatID: String, audioFormatID: String? = nil,
                videoCodec: String? = nil, audioCodec: String? = nil, needsTranscode: Bool,
                width: Int? = nil, height: Int? = nil, fps: Double? = nil, bitrate: Double? = nil,
                videoBitrate: Double? = nil,
                filesize: Int64? = nil, hasVideo: Bool? = true, hasAudio: Bool? = nil,
                language: String? = nil, languagePreference: Double? = nil, formatNote: String? = nil,
                audioChannels: Int? = nil, abr: Double? = nil, preference: Double? = nil,
                sourcePreference: Double? = nil, videoPreference: Double? = nil,
                videoSourcePreference: Double? = nil, sourceContainer: String? = nil,
                sourceProtocol: String? = nil, sourceBackend: String? = nil) {
        self.quality = quality
        self.container = container
        self.videoFormatID = videoFormatID
        self.audioFormatID = audioFormatID
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.needsTranscode = needsTranscode
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.videoBitrate = videoBitrate
        self.filesize = filesize
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.language = language
        self.languagePreference = languagePreference
        self.formatNote = formatNote
        self.audioChannels = audioChannels
        self.abr = abr
        self.preference = preference
        self.sourcePreference = sourcePreference
        self.videoPreference = videoPreference
        self.videoSourcePreference = videoSourcePreference
        self.sourceContainer = sourceContainer
        self.sourceProtocol = sourceProtocol
        self.sourceBackend = sourceBackend
    }
}

public enum ReelVariantResolutionMethod: String, Sendable, Equatable {
    case direct
    case remux
    case transcode
}

/// Typed result of resolving a picker selection to inspected source tracks.
/// The diagnostic string is bounded and intended for logs/tests, not UI copy.
public struct ReelVariantResolution: Sendable, Equatable {
    public let variant: ReelVariant
    public let requestedQuality: String
    public let targetContainer: String
    public let method: ReelVariantResolutionMethod
    public let usedLowerQualityFallback: Bool

    public init(variant: ReelVariant, requestedQuality: String, targetContainer: String,
                method: ReelVariantResolutionMethod, usedLowerQualityFallback: Bool) {
        self.variant = variant
        self.requestedQuality = requestedQuality
        self.targetContainer = targetContainer
        self.method = method
        self.usedLowerQualityFallback = usedLowerQualityFallback
    }

    public var diagnosticDescription: String {
        let audio = variant.audioFormatID.map { "audio=\($0)" } ?? "audio=embedded-or-none"
        let language = variant.language.map { " language=\($0)" } ?? ""
        let codecs = " codecs=\(variant.videoCodec ?? "unknown")/\(variant.audioCodec ?? "none")"
        let qualityDecision = usedLowerQualityFallback ? " fallback=lower-quality"
            : (requestedQuality == "best" ? " best-available" : " exact-quality")
        return String("requested=\(requestedQuality) \(targetContainer); selected=\(variant.quality) video=\(variant.videoFormatID) \(audio)\(language)\(codecs) method=\(method.rawValue)\(qualityDecision)".prefix(512))
    }
}

public struct ReelInspectionInfo: Codable, Sendable, Equatable {
    public let remoteURL: String
    public let title: String
    public let durationSeconds: Double?
    public let source: String
    public let isLive: Bool?
    public let qualities: [String]
    public let videoFormats: [String]
    public let audioAvailable: Bool?
    public let variants: [ReelVariant]

    public init(remoteURL: String, title: String, durationSeconds: Double?, source: String,
                isLive: Bool?, qualities: [String], videoFormats: [String], audioAvailable: Bool?,
                variants: [ReelVariant] = []) {
        self.remoteURL = remoteURL
        self.title = title
        self.durationSeconds = durationSeconds
        self.source = source
        self.isLive = isLive
        self.qualities = qualities
        self.videoFormats = videoFormats
        self.audioAvailable = audioAvailable
        self.variants = Array(variants.prefix(512))
    }

    private enum CodingKeys: String, CodingKey {
        case remoteURL, title, durationSeconds, source, isLive, qualities, videoFormats, audioAvailable, variants
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(remoteURL: try values.decode(String.self, forKey: .remoteURL),
                  title: try values.decode(String.self, forKey: .title),
                  durationSeconds: try values.decodeIfPresent(Double.self, forKey: .durationSeconds),
                  source: try values.decode(String.self, forKey: .source),
                  isLive: try values.decodeIfPresent(Bool.self, forKey: .isLive),
                  qualities: try values.decodeIfPresent([String].self, forKey: .qualities) ?? ["best"],
                  videoFormats: try values.decodeIfPresent([String].self, forKey: .videoFormats) ?? [],
                  audioAvailable: try values.decodeIfPresent(Bool.self, forKey: .audioAvailable),
                  variants: try values.decodeIfPresent([ReelVariant].self, forKey: .variants) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(remoteURL, forKey: .remoteURL)
        try values.encode(title, forKey: .title)
        try values.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try values.encode(source, forKey: .source)
        try values.encode(isLive, forKey: .isLive)
        try values.encode(qualities, forKey: .qualities)
        try values.encode(videoFormats, forKey: .videoFormats)
        try values.encode(audioAvailable, forKey: .audioAvailable)
        try values.encode(variants, forKey: .variants)
    }
}

public enum VideoTargetFormat: String, Codable, Sendable, CaseIterable {
    case mp4, mov, mkv, webm
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
    case batchRemoveImageBackground = "image.batchRemoveBackground"
    case inspectRemoteMedia = "remoteMedia.inspect"
    case downloadRemoteVideo = "remoteMedia.downloadVideo"
    case downloadRemoteAudio = "remoteMedia.downloadAudio"
    case downloadRemoteLive = "remoteMedia.downloadLive"
    case downloadRemoteSubtitles = "remoteMedia.downloadSubtitles"
    case downloadRemoteThumbnail = "remoteMedia.downloadThumbnail"
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
    case audioConvert(format: AudioTargetFormat)
    case videoConvert(format: VideoTargetFormat)
    case remoteMedia(quality: String?, format: String?)
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
        case .resizeImage, .batchResizeImages, .convertImage, .batchConvertImages, .compareImages, .findSimilarImages, .removeImageBackground, .batchRemoveImageBackground, .rotateImage, .inspectImage, .cropImage, .smartCropImage, .compressImage, .removeImageMetadata, .imageContactSheet: .pixel
        case .renameFile, .batchRename, .copyFiles, .moveFiles, .createFolder, .findDuplicates, .findRecent, .findByName,
             .organizeByType, .organizeByDate, .organizeByModulePattern, .organizeDownloads: .clerk
        case .createArchive, .inspectArchive, .extractZip, .compressPDF: .zip
        case .extractAudio, .transcribeAudio, .generateSubtitles, .extractMediaClip, .convertAudio, .inspectMedia, .thumbnailVideo, .trimVideo, .resizeVideo, .transcodeVideo, .compressVideo: .echo
        case .fetchURL, .extractWebLinks, .researchOpenSources: .scout
        case .summarizeText, .rewriteText, .proofreadText, .translateText, .keyPointsText, .actionItemsText, .toMarkdownText, .compareText, .explainText: .scribe
        case .inspectData, .mergeData, .deduplicateData, .sortData, .filterData, .selectColumns, .renameColumns, .reorderColumns,
             .dataStatistics, .csvToJSON, .jsonToCSV, .normalizeData, .compareData, .importXLSX: .table
        case .inspectRemoteMedia, .downloadRemoteVideo, .downloadRemoteAudio, .downloadRemoteLive,
             .downloadRemoteSubtitles, .downloadRemoteThumbnail: .reel
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

    public func contains(_ id: String) -> Bool { orderedIDs.contains(id) }

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
    case pointer, composing, attachments, dragging, pinned, working, resultInteraction, menuOrPopover, cueSession
}

public enum NotchMode: String, Sendable, Equatable {
    case idleComposer, preparing, working, result, clarificationError, cueSetup, cueActive
}

/// Pure presentation policy: collapsed surfaces never include character/content payloads.
public struct NotchPresentationState: Sendable, Equatable {
    public let expanded: Bool
    public let mode: NotchMode
    public let activeAgent: AgentID
    public let progress: Double

    public init(expanded: Bool, mode: NotchMode, activeAgent: AgentID, progress: Double) {
        self.expanded = expanded
        self.mode = mode
        self.activeAgent = activeAgent
        self.progress = min(1, max(0, progress))
    }

    public var exposesMascot: Bool { expanded && mode != .cueActive && progress > 0.22 }
    public var exposesContent: Bool { expanded && progress > 0.08 }
    public var clipsContentToShell: Bool { true }
    public var contentOpacity: Double { min(1, progress * 1.25) }
    public var allowsContentHitTesting: Bool { expanded && progress > 0.82 }

    public static func mode(cueActive: Bool, cueSetup: Bool, preparing: Bool,
                            taskStatus: TaskExecutionStatus?) -> NotchMode {
        if cueActive { return .cueActive }
        if cueSetup { return .cueSetup }
        if preparing { return .preparing }
        return switch taskStatus {
        case .planning: .preparing
        case .running: .working
        case .waitingForUser, .failed, .cancelled: .clarificationError
        case .completed: .result
        case .none: .idleComposer
        }
    }

    public static func activeAgent(for execution: TaskExecutionState?) -> AgentID {
        guard let execution else { return .kio }
        if (execution.status == .planning || (execution.status == .running && execution.currentStepIndex == nil)),
           let owner = execution.plan?.steps.first?.owner { return owner }
        return execution.activeAgent
    }
}

public enum MascotHandoffPhase: Sendable, Equatable {
    case coordinator
    case departing
    case landing
    case assigned
}

/// State sequence used by the notch to animate Kio's handoff without losing the active specialist.
public struct MascotHandoffState: Sendable, Equatable {
    public private(set) var activeAgent: AgentID = .kio
    public private(set) var targetAgent: AgentID = .kio
    public private(set) var phase: MascotHandoffPhase = .coordinator

    public init() {}

    public var displayedAgent: AgentID { phase == .departing ? .kio : activeAgent }
    public var coordinatorHasDeparted: Bool { phase == .departing || phase == .landing || phase == .assigned && activeAgent != .kio }
    public var agentHasArrived: Bool { phase == .landing || phase == .assigned && activeAgent != .kio }
    public var launchSmokeVisible: Bool { phase == .departing || phase == .landing }

    public mutating func beginDeparture(to agent: AgentID) {
        guard agent != .kio else { resetToCoordinator(); return }
        targetAgent = agent
        phase = .departing
    }

    public mutating func landTarget() {
        guard targetAgent != .kio else { return }
        activeAgent = targetAgent
        phase = .landing
    }

    public mutating func settle() {
        guard activeAgent != .kio else { return }
        phase = .assigned
    }

    public mutating func assignImmediately(_ agent: AgentID) {
        activeAgent = agent
        targetAgent = agent
        phase = agent == .kio ? .coordinator : .assigned
    }

    public mutating func resetToCoordinator() {
        activeAgent = .kio
        targetAgent = .kio
        phase = .coordinator
    }
}

public struct CharacterRolePose: Sendable, Equatable {
    public let scaleX: Double
    public let scaleY: Double
    public let offsetX: Double
    public let offsetY: Double
    public let rotationDegrees: Double

    public init(scaleX: Double = 1, scaleY: Double = 1, offsetX: Double = 0,
                offsetY: Double = 0, rotationDegrees: Double = 0) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.rotationDegrees = rotationDegrees
    }
}

public enum MascotHandoffMotionPolicy {
    public static let coordinatorDepartureDuration: TimeInterval = 1.35
    public static let landingDelay: Duration = .milliseconds(430)
    public static let landingSpringResponse: TimeInterval = 0.72
    public static let smokeHold: Duration = .milliseconds(1_400)
    public static let coordinatorReturnResponse: TimeInterval = 0.78
}

public enum CharacterMotionPolicy {
    public static let blinkDelaySeconds = 2.5...5.5
    public static let blinkCloseMilliseconds = 90...130
    public static let blinkOpenMilliseconds = 100...150
    public static let doubleBlinkProbability = 0.18
    public static let motionScale = 0.04

    public static func motionEnabled(systemReduceMotion: Bool, userReduceMotion: Bool) -> Bool {
        !systemReduceMotion && !userReduceMotion
    }

    public static func rolePose(for agent: AgentID, beat: Bool, reduceMotion: Bool) -> CharacterRolePose {
        guard !reduceMotion else { return CharacterRolePose() }
        let scales: (Double, Double)
        let offsets: (Double, Double)
        let rotations: (Double, Double)
        switch agent {
        case .pixel:
            scales = beat ? (1.045, 0.965) : (0.985, 1.02); offsets = (0, 0); rotations = (0, 0)
        case .zip:
            scales = beat ? (0.94, 1.045) : (1.025, 0.985); offsets = (0, 0); rotations = (0, 0)
        case .echo:
            scales = beat ? (1.025, 1.025) : (0.99, 0.99); offsets = (0, 0); rotations = (0, 0)
        case .table:
            scales = beat ? (1.035, 0.975) : (0.98, 1.025); offsets = (0, 0); rotations = (0, 0)
        case .lens:
            scales = beat ? (1.025, 1.035) : (0.99, 0.985); offsets = (0, 0); rotations = (0, 0)
        case .reel:
            scales = beat ? (1.035, 0.97) : (0.98, 1.025)
            offsets = beat ? (0.018, -0.02) : (-0.018, 0)
            rotations = beat ? (-2.2, 0) : (2.2, 0)
        case .cue:
            scales = beat ? (1.012, 0.995) : (0.995, 1.012)
            offsets = beat ? (0.012, 0) : (-0.012, 0)
            rotations = beat ? (-0.5, 0) : (0.5, 0)
        case .pip:
            scales = (1, 1); offsets = beat ? (0, -0.045) : (0, 0); rotations = beat ? (-1, 0) : (0.6, 0)
        case .clerk:
            scales = (1, 1); offsets = beat ? (0.025, 0) : (-0.025, 0); rotations = (0, 0)
        case .courier:
            scales = (1, 1); offsets = beat ? (0.035, -0.035) : (-0.02, 0); rotations = beat ? (2.2, 0) : (-0.8, 0)
        case .patch:
            scales = (1, 1); offsets = beat ? (0.035, 0) : (-0.035, 0); rotations = (0, 0)
        case .scribe:
            scales = (1, 1); offsets = (0, 0); rotations = beat ? (-1.8, 0) : (1.2, 0)
        case .scout:
            scales = (1, 1); offsets = (0, 0); rotations = beat ? (-2.2, 0) : (2.2, 0)
        case .kio:
            scales = (1, 1); offsets = (0, 0); rotations = (0, 0)
        }
        return CharacterRolePose(scaleX: scales.0, scaleY: scales.1, offsetX: offsets.0,
                                 offsetY: offsets.1, rotationDegrees: rotations.0)
    }

    public static func blinkDelay(sample: Double) -> TimeInterval {
        let value = min(1, max(0, sample.isFinite ? sample : 0))
        return blinkDelaySeconds.lowerBound + value * (blinkDelaySeconds.upperBound - blinkDelaySeconds.lowerBound)
    }

    public static func blinkCloseDuration(sample: Double) -> TimeInterval {
        let value = min(1, max(0, sample.isFinite ? sample : 0))
        let milliseconds = Double(blinkCloseMilliseconds.lowerBound)
            + value * Double(blinkCloseMilliseconds.upperBound - blinkCloseMilliseconds.lowerBound)
        return milliseconds / 1_000
    }

    public static func blinkOpenDuration(sample: Double) -> TimeInterval {
        let value = min(1, max(0, sample.isFinite ? sample : 0))
        let milliseconds = Double(blinkOpenMilliseconds.lowerBound)
            + value * Double(blinkOpenMilliseconds.upperBound - blinkOpenMilliseconds.lowerBound)
        return milliseconds / 1_000
    }

    public static func choosesDoubleBlink(sample: Double) -> Bool {
        sample.isFinite && sample >= 0 && sample < doubleBlinkProbability
    }
}

/// Centralizes the reasons the expanded notch must remain available for interaction.
public struct NotchInteractionState: Sendable, Equatable {
    private var activeReasons = Set<NotchInteractionReason>()

    public init() {}

    public mutating func set(_ reason: NotchInteractionReason, active: Bool) {
        if active { activeReasons.insert(reason) }
        else { activeReasons.remove(reason) }
    }

    public mutating func setCueSession(_ active: Bool) {
        set(.cueSession, active: active)
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
