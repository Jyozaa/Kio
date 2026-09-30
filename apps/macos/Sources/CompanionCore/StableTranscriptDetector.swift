import Foundation

/// Bounded, deterministic stability gate for rolling local STT hypotheses.
/// It never decides whether an action is safe; it only reports a repeated,
/// complete-looking clause to the host.
public struct StableTranscriptDetector: Sendable {
    private let requiredRepeats: Int
    private let maxLength: Int
    private var recent: [[SemanticVoiceStep]] = []
    private var emitted = Set<String>()

    public init(requiredRepeats: Int = 2, maxLength: Int = 400) {
        self.requiredRepeats = max(1, requiredRepeats)
        self.maxLength = max(40, maxLength)
    }

    public mutating func observe(_ candidate: String) -> String? {
        observeSteps(candidate).first?.sourceText
    }

    /// Emits each safe semantic clause only after it has appeared in the
    /// required number of recent rolling hypotheses.
    public mutating func observeSteps(_ candidate: String) -> [SemanticVoiceStep] {
        let value = String(candidate.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
        guard !value.isEmpty else { return [] }
        let steps = SemanticVoiceStepParser.parseAll(value)
        guard !steps.isEmpty else { return [] }
        recent.append(steps)
        if recent.count > requiredRepeats { recent.removeFirst() }
        guard recent.count == requiredRepeats else { return [] }
        var newlyStable: [SemanticVoiceStep] = []
        for step in steps where !emitted.contains(step.id) {
            guard recent.allSatisfy({ $0.contains(where: { $0.id == step.id }) }) else { continue }
            emitted.insert(step.id)
            newlyStable.append(step)
        }
        return newlyStable
    }

    public mutating func reset() {
        recent.removeAll(keepingCapacity: true)
        emitted.removeAll(keepingCapacity: true)
    }

}
