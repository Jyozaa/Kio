import Foundation
import KioCore

public struct WorkflowTemplate: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public let inputKinds: [ArtifactKind]
    public let steps: [WorkflowTemplateStep]

    public init(id: UUID = UUID(), name: String, createdAt: Date = .now, inputKinds: [ArtifactKind], steps: [WorkflowTemplateStep]) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.inputKinds = inputKinds
        self.steps = steps
    }
}

public struct WorkflowTemplateStep: Codable, Sendable {
    public enum Source: Codable, Sendable {
        case inputs([Int])
        case previousStep(Int)
    }

    public let operation: ToolOperation
    public let source: Source
    public let arguments: ToolArguments

    public init(operation: ToolOperation, source: Source, arguments: ToolArguments) {
        self.operation = operation
        self.source = source
        self.arguments = arguments
    }
}

/// Local typed operation graphs only. No paths, model-generated code, or shell commands are stored.
public struct WorkflowTemplateStore {
    private let key: String
    private let defaults: UserDefaults

    private static let safeOperations: Set<ToolOperation> = [
        .mergePDFs, .removePDFPages, .removeBlankPDFPages, .splitPDF, .extractPDFPages,
        .reorderPDFPages, .rotatePDFPages, .extractPDFText, .ocrPDFText, .inspectPDF, .searchPDFText,
        .imagesToPDF, .resizeImage, .batchResizeImages, .convertImage, .batchConvertImages,
        .compareImages, .findSimilarImages, .removeImageBackground, .batchRemoveImageBackground, .rotateImage, .inspectImage, .cropImage,
        .compressImage, .removeImageMetadata, .imageContactSheet, .createArchive, .inspectArchive,
        .extractZip, .compressPDF, .extractAudio, .transcribeAudio, .generateSubtitles, .extractMediaClip, .convertAudio, .inspectMedia, .thumbnailVideo, .trimVideo,
        .resizeVideo, .transcodeVideo, .compressVideo, .findRecent, .findByName, .summarizeText, .rewriteText,
        .proofreadText, .translateText, .keyPointsText, .actionItemsText, .toMarkdownText,
        .compareText, .explainText, .inspectData, .mergeData, .deduplicateData, .sortData,
        .filterData, .selectColumns, .renameColumns, .reorderColumns, .dataStatistics,
        .findDuplicates, .organizeByType, .organizeByDate, .organizeByModulePattern, .organizeDownloads,
        .csvToJSON, .jsonToCSV, .normalizeData, .compareData, .importXLSX, .fetchURL, .extractWebLinks,
        .ocrImage, .extractImageTable, .extractReceipt, .extractStructuredText,
        .explainCode, .proposePatch, .formatJSON,
        .inspectRemoteMedia, .downloadRemoteVideo, .downloadRemoteAudio, .downloadRemoteLive,
        .downloadRemoteSubtitles, .downloadRemoteThumbnail
    ]

    public init(key: String = "kio.workflowTemplates.v1", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    public func load() -> [WorkflowTemplate] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([WorkflowTemplate].self, from: data) else { return [] }
        return Array(decoded.filter(Self.isStructurallyValid).prefix(50))
    }

    public static func isListingRequest(_ request: String) -> Bool {
        let words = request.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let asksToList = words.contains(where: { ["list", "show", "see", "view", "what"].contains($0) })
        let namesWorkflows = words.contains(where: { ["workflow", "workflows", "template", "templates"].contains($0) })
        return asksToList && namesWorkflows
    }

    public func listingReply() -> String {
        Self.listingReply(for: load())
    }

    public static func listingReply(for templates: [WorkflowTemplate]) -> String {
        guard !templates.isEmpty else {
            return "You don't have any saved workflow templates yet. Save a completed workflow in Kio on your Mac, then ask me to list them again."
        }
        let entries = templates.map { template in
            let kinds = template.inputKinds.map(\.rawValue).joined(separator: ", ")
            return "• \(template.name) — \(template.steps.count) step\(template.steps.count == 1 ? "" : "s"); input: \(kinds)"
        }.joined(separator: "\n")
        return "Saved Kio workflows:\n\n\(entries)\n\nTo run one, send “Run <name> on these” with compatible files attached."
    }

    @discardableResult
    public func save(name rawName: String, plan: TaskPlan, inputs: [ArtifactRef]) throws -> [WorkflowTemplate] {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { throw Self.failure("Use a workflow name up to 60 characters.") }
        let existing = load()
        guard existing.count < 50 || existing.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw Self.failure("Kio stores up to 50 local workflow templates.")
        }
        guard !inputs.isEmpty, inputs.count <= 32, !plan.steps.isEmpty, plan.steps.count <= 12 else {
            throw Self.failure("This workflow cannot be saved safely.")
        }
        let inputIndices = Dictionary(inputs.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let stepIndices = Dictionary(plan.steps.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var storedSteps: [WorkflowTemplateStep] = []
        var priorOutputKinds: [[ArtifactKind]] = []
        for (index, step) in plan.steps.enumerated() {
            guard Self.safeOperations.contains(step.operation), FastPathPlanner.hasValidArguments(step.arguments, for: step.operation) else {
                throw Self.failure("This workflow includes an operation or argument that templates cannot safely repeat.")
            }
            let source: WorkflowTemplateStep.Source
            let inputKinds: [ArtifactKind]
            switch step.source {
            case .artifacts(let ids):
                let positions = ids.compactMap { inputIndices[$0] }
                guard !ids.isEmpty, positions.count == ids.count else { throw Self.failure("This workflow references an unavailable input.") }
                source = .inputs(positions)
                inputKinds = positions.map { inputs[$0].kind }
            case .previousStep(let id):
                guard let previous = stepIndices[id], previous < index, let kinds = priorOutputKinds[safe: previous] else {
                    throw Self.failure("This workflow contains an invalid step dependency.")
                }
                source = .previousStep(previous)
                inputKinds = kinds
            }
            guard FastPathPlanner.isCompatible(step.operation, inputKinds: inputKinds) else {
                throw Self.failure("This workflow's input types do not match its registered operations.")
            }
            priorOutputKinds.append(FastPathPlanner.outputKinds(for: step.operation, inputKinds: inputKinds))
            storedSteps.append(WorkflowTemplateStep(operation: step.operation, source: source, arguments: step.arguments))
        }
        let candidate = WorkflowTemplate(name: name, inputKinds: inputs.map(\.kind), steps: storedSteps)
        guard Self.isStructurallyValid(candidate) else { throw Self.failure("This workflow cannot be saved safely.") }
        var templates = existing
        if let existingIndex = templates.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            templates[existingIndex] = WorkflowTemplate(id: templates[existingIndex].id, name: name,
                                                        createdAt: templates[existingIndex].createdAt,
                                                        inputKinds: candidate.inputKinds, steps: candidate.steps)
        } else { templates.append(candidate) }
        try persist(templates)
        return templates
    }

    public func instantiate(_ template: WorkflowTemplate, request: String, inputs: [ArtifactRef]) throws -> TaskPlan {
        guard Self.isStructurallyValid(template), inputs.count == template.inputKinds.count,
              zip(inputs, template.inputKinds).allSatisfy({ pair in pair.0.kind == pair.1 }) else {
            throw Self.failure("The saved workflow needs a different number or type of input files.")
        }
        var ids: [UUID] = []
        var steps: [TaskStep] = []
        var priorOutputKinds: [[ArtifactKind]] = []
        for (index, step) in template.steps.enumerated() {
            guard FastPathPlanner.hasValidArguments(step.arguments, for: step.operation) else {
                throw Self.failure("The saved workflow contains invalid arguments.")
            }
            let id = UUID()
            let source: StepSource
            let inputKinds: [ArtifactKind]
            switch step.source {
            case .inputs(let positions):
                guard !positions.isEmpty, positions.allSatisfy(inputs.indices.contains) else { throw Self.failure("The saved workflow references an unavailable input.") }
                source = .artifacts(positions.map { inputs[$0].id })
                inputKinds = positions.map { inputs[$0].kind }
            case .previousStep(let previous):
                guard previous < index, ids.indices.contains(previous), let kinds = priorOutputKinds[safe: previous] else {
                    throw Self.failure("The saved workflow has an invalid step dependency.")
                }
                source = .previousStep(ids[previous])
                inputKinds = kinds
            }
            guard FastPathPlanner.isCompatible(step.operation, inputKinds: inputKinds) else {
                throw Self.failure("The saved workflow's steps are not compatible with these files.")
            }
            steps.append(TaskStep(id: id, operation: step.operation, source: source, arguments: step.arguments))
            ids.append(id)
            priorOutputKinds.append(FastPathPlanner.outputKinds(for: step.operation, inputKinds: inputKinds))
        }
        return TaskPlan(request: request, steps: steps)
    }

    public func rename(id: UUID, to rawName: String) throws -> [WorkflowTemplate] {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { throw Self.failure("Use a workflow name up to 60 characters.") }
        var templates = load()
        guard let index = templates.firstIndex(where: { $0.id == id }) else { throw Self.failure("That workflow is no longer available.") }
        guard !templates.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw Self.failure("A workflow already uses that name.")
        }
        templates[index].name = name
        try persist(templates)
        return templates
    }

    public func delete(id: UUID) throws -> [WorkflowTemplate] {
        var templates = load()
        templates.removeAll { $0.id == id }
        try persist(templates)
        return templates
    }

    public static func requestedName(in request: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)^\s*(?:run|use)\s+(.+?)\s+(?:on|with)\s+(?:these|this|them|it)\s*[.!]?\s*$"#),
              let match = regex.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)),
              let range = Range(match.range(at: 1), in: request) else { return nil }
        return String(request[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isStructurallyValid(_ template: WorkflowTemplate) -> Bool {
        guard !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              template.name.count <= 60, !template.inputKinds.isEmpty, template.inputKinds.count <= 32,
              !template.steps.isEmpty, template.steps.count <= 12 else { return false }
        return template.steps.enumerated().allSatisfy { index, step in
            guard safeOperations.contains(step.operation), FastPathPlanner.hasValidArguments(step.arguments, for: step.operation) else { return false }
            let sourceIsValid: Bool
            switch step.source {
            case .inputs(let positions): sourceIsValid = !positions.isEmpty && positions.count <= 32 && Set(positions).count == positions.count && positions.allSatisfy(template.inputKinds.indices.contains)
            case .previousStep(let previous): sourceIsValid = previous >= 0 && previous < index
            }
            return sourceIsValid
        }
    }

    private func persist(_ templates: [WorkflowTemplate]) throws {
        defaults.set(try JSONEncoder().encode(templates), forKey: key)
    }

    private static func failure(_ message: String) -> KioFailure { .invalidInput(message) }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
