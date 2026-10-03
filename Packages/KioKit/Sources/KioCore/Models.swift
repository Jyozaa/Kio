import Foundation
import UniformTypeIdentifiers

public enum ArtifactKind: String, Codable, CaseIterable, Sendable { case pdf, image, audio, video, text, url, other }
public enum ArtifactRole: String, Codable, Sendable { case userInput, userResult, internalIntermediate }
public enum AudioTargetFormat: String, Codable, CaseIterable, Sendable { case mp3, m4a, wav, flac }

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

    public init(id: UUID = UUID(), displayName: String, kind: ArtifactKind, fileURL: URL, sizeBytes: Int64,
                createdAt: Date = .now, parentID: UUID? = nil, verificationNote: String? = nil, role: ArtifactRole? = nil) {
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
        self.init(id: try values.decode(UUID.self, forKey: .id), displayName: try values.decode(String.self, forKey: .displayName),
                  kind: try values.decode(ArtifactKind.self, forKey: .kind), fileURL: fileURL,
                  sizeBytes: try values.decode(Int64.self, forKey: .sizeBytes), createdAt: try values.decode(Date.self, forKey: .createdAt),
                  parentID: parentID, verificationNote: try values.decodeIfPresent(String.self, forKey: .verificationNote), role: role)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(displayName, forKey: .displayName)
        try values.encode(kind, forKey: .kind); try values.encode(fileURL, forKey: .fileURL)
        try values.encode(sizeBytes, forKey: .sizeBytes); try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(parentID, forKey: .parentID); try values.encodeIfPresent(verificationNote, forKey: .verificationNote)
        try values.encode(role, forKey: .role)
    }

    public static func inspect(_ url: URL, parentID: UUID? = nil) throws -> ArtifactRef {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentTypeKey])
        let type = values.contentType
        let kind: ArtifactKind
        if values.isDirectory == true { kind = .other }
        else if type?.conforms(to: .pdf) == true { kind = .pdf }
        else if type?.conforms(to: .image) == true { kind = .image }
        else if type?.conforms(to: .audio) == true { kind = .audio }
        else if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { kind = .video }
        else if url.pathExtension.lowercased() == "kio-reel-info" { kind = .other }
        else if type?.conforms(to: .text) == true { kind = .text }
        else { kind = .other }
        let role: ArtifactRole = url.pathExtension.lowercased() == "kio-reel-info" ? .internalIntermediate : (parentID == nil ? .userInput : .userResult)
        return ArtifactRef(displayName: url.lastPathComponent, kind: kind, fileURL: url,
                           sizeBytes: Int64(values.fileSize ?? 0), parentID: parentID, role: role)
    }

    public var isAvailableLocally: Bool {
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        return (try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])) != nil
    }

    public func refreshedFromDisk() -> ArtifactRef? {
        guard isAvailableLocally, let current = try? Self.inspect(fileURL, parentID: parentID), current.kind == kind else { return nil }
        return ArtifactRef(id: id, displayName: current.displayName, kind: current.kind, fileURL: current.fileURL,
                           sizeBytes: current.sizeBytes, createdAt: createdAt, parentID: parentID,
                           verificationNote: verificationNote, role: role)
    }

    public func withVerificationNote(_ note: String?) -> ArtifactRef {
        ArtifactRef(id: id, displayName: displayName, kind: kind, fileURL: fileURL, sizeBytes: sizeBytes,
                    createdAt: createdAt, parentID: parentID, verificationNote: note, role: role)
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

    /// Quality picker choices that have inspected source variants. `best` is a
    /// resolver request, so it is available even though variants carry concrete
    /// source heights rather than a synthetic `best` height.
    public var availableQualities: [String] {
        guard !variants.isEmpty else { return qualities.isEmpty ? ["best"] : qualities }
        let variantQualities = Set(variants.map(\.quality))
        return ["best"] + qualities.filter { $0 != "best" && variantQualities.contains($0) }
    }

    /// Formats that the resolver can consider for a picker selection. `best`
    /// must inspect every container because the best source height can differ
    /// by container; concrete heights stay restricted to their exact variants.
    public func availableVideoFormats(for quality: String) -> [String] {
        guard !variants.isEmpty else { return videoFormats.isEmpty ? ["mp4"] : videoFormats }
        let matching = quality == "best" ? variants : variants.filter { $0.quality == quality }
        // The selector creates target-container candidates for every source
        // track. The picker should expose containers actually present at the
        // requested source quality, not synthetic transcode destinations.
        let sourceFormats = matching.compactMap { $0.sourceContainer?.lowercased() }
        return Array(Set(sourceFormats.isEmpty ? matching.map(\.container) : sourceFormats)).sorted()
    }

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
    case mergePDFs = "pdf.merge", imagesToPDF = "image.toPDF", compressPDF = "pdf.compress"
    case resizeImage = "image.resize", batchResizeImages = "image.batchResize"
    case convertImage = "image.convert", batchConvertImages = "image.batchConvert", compressImage = "image.compress"
    case extractAudio = "media.extractAudio", convertAudio = "audio.convert"
    case resizeVideo = "media.resizeVideo", transcodeVideo = "media.transcode", compressVideo = "media.compressVideo"
    case inspectRemoteMedia = "remoteMedia.inspect", downloadRemoteVideo = "remoteMedia.downloadVideo"
    case downloadRemoteAudio = "remoteMedia.downloadAudio", downloadRemoteLive = "remoteMedia.downloadLive"
    case downloadRemoteSubtitles = "remoteMedia.downloadSubtitles", downloadRemoteThumbnail = "remoteMedia.downloadThumbnail"
}

public enum StepSource: Codable, Sendable, Hashable { case artifacts([UUID]) }
public enum ToolArguments: Codable, Sendable, Hashable {
    case none
    case imageResize(width: Int)
    case imageConvert(format: String)
    case audioConvert(format: AudioTargetFormat)
    case videoConvert(format: VideoTargetFormat)
    case remoteMedia(quality: String?, format: String?)
    case imageCompression(maxBytes: Int64?)
    case mediaResize(width: Int)
    case mediaCompression(maxBytes: Int64?)
    case pdfCompression(maxBytes: Int64?)
}

public struct TaskStep: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let operation: ToolOperation
    public let source: StepSource
    public let arguments: ToolArguments
    public init(id: UUID = UUID(), operation: ToolOperation, source: StepSource, arguments: ToolArguments = .none) {
        self.id = id; self.operation = operation; self.source = source; self.arguments = arguments
    }
}

public enum KioFailure: Error, LocalizedError, Sendable {
    case unsupported(String), invalidInput(String), processing(String), verification(String)
    public var errorDescription: String? {
        switch self { case .unsupported(let message), .invalidInput(let message), .processing(let message), .verification(let message): message }
    }
}
