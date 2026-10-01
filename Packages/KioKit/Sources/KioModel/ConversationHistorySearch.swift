import Foundation
import KioCore

/// Searchable local conversation metadata. It intentionally contains no file
/// contents beyond the text already shown in the local conversation.
public struct ConversationHistoryRecord: Identifiable, Sendable {
    public let id: UUID
    public let speaker: String
    public let message: String
    public let artifact: ArtifactRef?
    public let operation: ToolOperation?
    public let createdAt: Date

    public init(id: UUID, speaker: String, message: String, artifact: ArtifactRef?, operation: ToolOperation?, createdAt: Date) {
        self.id = id
        self.speaker = speaker
        self.message = message
        self.artifact = artifact
        self.operation = operation
        self.createdAt = createdAt
    }
}

public enum ConversationHistorySearch {
    private static let ignoredWords: Set<String> = [
        "a", "an", "and", "by", "did", "do", "find", "for", "from", "i", "in", "is", "me",
        "my", "of", "on", "show", "the", "that", "this", "to", "was", "were", "where", "yesterday", "today", "agent", "task"
    ]

    /// Deterministic metadata/text search, scoped exclusively to supplied Kio history.
    public static func filter(
        _ records: [ConversationHistoryRecord],
        query rawQuery: String,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [ConversationHistoryRecord] {
        let words = rawQuery.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return records }
        let tokens = Set(words)
        let hasYesterday = tokens.contains("yesterday")
        let hasToday = tokens.contains("today")
        let normalizedTerms = words
            .filter { !ignoredWords.contains($0) }
            .map(normalize)
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)

        return records.filter { record in
            if hasYesterday {
                guard let startOfYesterday,
                      record.createdAt >= startOfYesterday,
                      record.createdAt < startOfToday else { return false }
            }
            if hasToday, record.createdAt < startOfToday { return false }

            let fields = [
                record.speaker,
                record.message,
                record.artifact?.displayName ?? "",
                record.artifact?.kind.rawValue ?? "",
                record.operation?.rawValue ?? "",
                record.createdAt.formatted(date: .long, time: .shortened),
                record.createdAt.formatted(date: .numeric, time: .omitted)
            ].joined(separator: " ").lowercased()
            let normalizedHaystack = Self.normalize(fields)
            return normalizedTerms.allSatisfy { normalizedHaystack.contains($0) }
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "compressed", with: "compress")
            .replacingOccurrences(of: "compressing", with: "compress")
            .replacingOccurrences(of: "compression", with: "compress")
            .replacingOccurrences(of: "summarized", with: "summarize")
            .replacingOccurrences(of: "summarised", with: "summarize")
            .replacingOccurrences(of: "summarizing", with: "summarize")
            .replacingOccurrences(of: "summary", with: "summarize")
            .replacingOccurrences(of: "converted", with: "convert")
            .replacingOccurrences(of: "conversion", with: "convert")
            .replacingOccurrences(of: "deduplicated", with: "deduplicate")
            .replacingOccurrences(of: "merged", with: "merge")
            .replacingOccurrences(of: "transcribed", with: "transcribe")
            .replacingOccurrences(of: "transcription", with: "transcribe")
    }
}
