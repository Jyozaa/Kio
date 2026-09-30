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
    case imagesToPDF = "image.toPDF"
    case resizeImage = "image.resize"
    case convertImage = "image.convert"
    case renameFile = "file.rename"
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
    case exactRename(name: String)
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
        case .renameFile, .batchRename: .clerk
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
    case pointer, inputFocus, composing, attachments, dragging, pinned, working, resultInteraction
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
