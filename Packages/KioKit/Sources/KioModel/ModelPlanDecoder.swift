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
        case .removePDFPages, .compressPDF: kinds.count == 1 && kinds[0] == .pdf
        case .imagesToPDF: !kinds.isEmpty && kinds.allSatisfy { $0 == .image }
        case .resizeImage, .convertImage: kinds.count == 1 && kinds[0] == .image
        case .batchRename, .createArchive: !kinds.isEmpty
        case .extractAudio: kinds.count == 1 && kinds[0] == .video
        }
    }

    private static func typedArguments(_ wire: WireArguments?, for operation: ToolOperation) -> ToolArguments? {
        switch operation {
        case .mergePDFs, .imagesToPDF, .createArchive, .extractAudio:
            return ToolArguments.none
        case .removePDFPages:
            guard let pages = wire?.pages, !pages.isEmpty, pages.count <= 200,
                  pages.allSatisfy({ (1...100_000).contains($0) }) else { return nil }
            return .removePages(indices: Array(Set(pages)).sorted())
        case .resizeImage:
            guard let width = wire?.width, (1...20_000).contains(width) else { return nil }
            return .imageResize(width: width)
        case .convertImage:
            guard let format = wire?.format?.lowercased(), ["png", "jpg", "jpeg"].contains(format) else { return nil }
            return .imageConvert(format: format == "jpg" ? "jpeg" : format)
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
        case .mergePDFs, .removePDFPages, .imagesToPDF, .compressPDF: [.pdf]
        case .resizeImage, .convertImage: [.image]
        case .batchRename: inputKinds
        case .createArchive: [.other]
        case .extractAudio: [.audio]
        }
    }

    private struct WirePlan: Decodable {
        let steps: [WireStep]
        let clarification: String?
    }

    private struct WireStep: Decodable {
        let operation: String
        let inputIndexes: [Int]?
        let previousStepIndex: Int?
        let arguments: WireArguments?
    }

    private struct WireArguments: Decodable {
        let width: Int?
        let format: String?
        let prefix: String?
        let pages: [Int]?
        let maxBytes: Int64?
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
