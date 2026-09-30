import Foundation
import UniformTypeIdentifiers

public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case pdf, image, audio, video, text, csv, folder, other
}

public enum AgentID: String, Codable, CaseIterable, Sendable, Identifiable {
    case kio, pip, pixel, zip, echo, clerk, courier

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
        else if url.pathExtension.lowercased() == "csv" { kind = .csv }
        else if type?.conforms(to: .text) == true { kind = .text }
        else { kind = .other }
        return ArtifactRef(displayName: url.lastPathComponent, kind: kind, fileURL: url, sizeBytes: Int64(values.fileSize ?? 0), parentID: parentID)
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
    case imagesToPDF = "image.toPDF"
    case resizeImage = "image.resize"
    case convertImage = "image.convert"
    case batchRename = "file.batchRename"
    case createArchive = "archive.createZip"
    case compressPDF = "pdf.compress"
    case extractAudio = "media.extractAudio"
}

public enum StepSource: Codable, Sendable, Hashable {
    case artifacts([UUID])
    case previousStep(UUID)
}

public enum ToolArguments: Codable, Sendable, Hashable {
    case none
    case imageResize(width: Int)
    case imageConvert(format: String)
    case rename(prefix: String)
    case removePages(indices: [Int])
    case pdfCompression(maxBytes: Int64?)
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

    public var owner: AgentID {
        switch operation {
        case .mergePDFs, .removePDFPages, .imagesToPDF: .pip
        case .resizeImage, .convertImage: .pixel
        case .batchRename: .clerk
        case .createArchive, .compressPDF: .zip
        case .extractAudio: .echo
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
