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

        let errors = ModelPlanDecoder.validationErrors(firstResponse, request: request, artifacts: artifacts)
        let prior = sanitizedPriorResponse(firstResponse)
        let errorList = errors.prefix(8).map { "- \(String($0.prefix(240)))" }.joined(separator: "\n")

        let repairPrompt = """
        \(initialPrompt)

        Repair attempt: the bounded structured response below failed validation. Correct only the reported fields and return one plan using the same typed JSON contract.

        Validation errors:
        \(errorList.isEmpty ? "- Response structure or registered capability was invalid." : errorList)

        Prior response (sanitized, with free-form values removed):
        \(prior)

        Do not add tools, filesystem paths, commands, credentials, or extra fields. One repair attempt is allowed.
        """
        guard let repairedResponse = try await generate(repairPrompt) else { return nil }
        return ModelPlanDecoder.decode(repairedResponse, request: request, artifacts: artifacts)
    }

    private static func sanitizedPriorResponse(_ response: String) -> String {
        guard response.utf8.count <= 32_000, let data = response.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = root["steps"] as? [[String: Any]] else {
            return "<malformed JSON omitted>"
        }
        let safeSteps: [[String: Any]] = steps.prefix(8).map { item in
            var safe: [String: Any] = [:]
            if let name = item["operation"] as? String {
                safe["operation"] = ToolOperation(rawValue: name)?.rawValue ?? "<unregistered operation>"
            }
            if let values = item["inputIndexes"] as? [Int] { safe["inputIndexes"] = Array(values.prefix(32)) }
            if let value = item["previousStepIndex"] as? Int { safe["previousStepIndex"] = value }
            if let arguments = item["arguments"] as? [String: Any] {
                var safeArguments: [String: Any] = [:]
                for (key, value) in arguments where ["width", "x", "y", "height", "maxBytes", "timeMs", "startMs", "durationMs", "degrees", "ascending"].contains(key) {
                    if let number = value as? NSNumber { safeArguments[key] = number }
                }
                for key in ["format", "quality"] {
                    if let value = arguments[key] as? String,
                       ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "webp", "mp3", "m4a", "wav", "flac", "mp4", "webm", "mkv", "mov", "best", "2160p", "1440p", "1080p", "720p", "480p", "360p"].contains(value.lowercased()) {
                        safeArguments[key] = value.lowercased()
                    }
                }
                for key in ["name", "prefix", "column", "value", "from", "to", "columns"] where arguments[key] != nil {
                    safeArguments[key] = "<redacted>"
                }
                safe["arguments"] = safeArguments
            }
            return safe
        }
        let sanitized: [String: Any] = ["steps": safeSteps]
        guard let encoded = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8) else { return "<response omitted>" }
        return String(text.prefix(6_000))
    }
}
