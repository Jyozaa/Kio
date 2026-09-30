import Foundation
import KioCore

/// Makes at most one repair retry after the first model response fails typed validation.
public enum ModelPlanRepair {
    @MainActor
    public static func plan(
        request: String,
        artifacts: [ArtifactRef],
        initialPrompt: String,
        generate: (String) async throws -> String?
    ) async throws -> TaskPlan? {
        guard let firstResponse = try await generate(initialPrompt) else { return nil }
        if let plan = ModelPlanDecoder.decode(firstResponse, request: request, artifacts: artifacts) {
            return plan
        }

        let repairPrompt = """
        \(initialPrompt)

        Repair attempt: the previous response did not pass Kio's strict typed-plan validation. Check that every operation is registered, each input index exists, each step has exactly one valid source, and arguments match the operation. Return one corrected plan using the same structured output format. Do not add tools, paths, commands, or extra fields.
        """
        guard let repairedResponse = try await generate(repairPrompt) else { return nil }
        return ModelPlanDecoder.decode(repairedResponse, request: request, artifacts: artifacts)
    }
}
