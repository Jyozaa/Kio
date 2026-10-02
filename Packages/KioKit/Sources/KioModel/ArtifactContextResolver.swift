import Foundation
import KioCore

public struct ArtifactContextEntry: Sendable {
    public let artifact: ArtifactRef
    public let operation: ToolOperation?
    public let speaker: String
    public let createdAt: Date

    public init(artifact: ArtifactRef, operation: ToolOperation?, speaker: String, createdAt: Date = .now) {
        self.artifact = artifact
        self.operation = operation
        self.speaker = speaker
        self.createdAt = createdAt
    }

    public var producingAgent: AgentID? { operation?.owner ?? AgentID(rawValue: speaker.lowercased()) }
}

public enum ArtifactContextResolution: Sendable {
    case notReferenced
    case resolved(ArtifactRef)
    case clarify(String)
}

/// Resolves only local Kio result metadata. It never searches the filesystem and
/// returns a clarification whenever the available context does not identify one result.
public struct ArtifactContextResolver: Sendable {
    public init() {}

    public func resolve(
        request rawRequest: String,
        history: [ArtifactContextEntry],
        mostRecentTaskResults: [ArtifactContextEntry],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ArtifactContextResolution {
        let request = rawRequest.lowercased()
        let tokens = Set(request.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let hasOrdinal = tokens.contains("first") || tokens.contains("second") || tokens.contains("third") ||
            tokens.contains("1st") || tokens.contains("2nd") || tokens.contains("3rd")
        let latestReference = tokens.contains("latest") || tokens.contains("last") || tokens.contains("previous") ||
            request.contains("from before") || request.contains("output before") || request.contains("most recent")
        let kindMention = Self.mentionedKind(in: tokens)
        let agentMention = AgentID.allCases.first { tokens.contains($0.rawValue) }
        let operationFilter = Self.operationFilter(in: tokens)
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? .distantPast
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? .distantFuture
        let dateFilter: ((Date) -> Bool)? = tokens.contains("yesterday") ? {
            $0 >= startOfYesterday && $0 < startOfToday
        } : (tokens.contains("today") ? {
            $0 >= startOfToday && $0 < startOfTomorrow
        } : nil)
        let hasReference = hasOrdinal || latestReference || kindMention != nil || agentMention != nil || operationFilter != nil ||
            !tokens.isDisjoint(with: ["it", "that", "those", "these", "one", "ones", "result", "output"])
        guard hasReference else { return .notReferenced }

        var candidates = history.filter { entry in
            entry.artifact.role != .internalIntermediate && entry.artifact.isAvailableLocally &&
                (kindMention == nil || Self.matches(kindMention!, entry.artifact.kind)) &&
                (agentMention == nil || entry.producingAgent == agentMention) &&
                (operationFilter == nil || operationFilter!(entry.operation)) &&
                (dateFilter == nil || dateFilter!(entry.createdAt))
        }
        candidates.sort { $0.createdAt < $1.createdAt }

        if kindMention == nil, agentMention == nil, operationFilter == nil, dateFilter == nil,
           !hasOrdinal, !latestReference,
           !tokens.isDisjoint(with: ["it", "that", "those", "these", "one", "ones", "result", "output"]),
           let latest = mostRecentTaskResults.last(where: { $0.artifact.isAvailableLocally })?.artifact ?? candidates.last?.artifact {
            return .resolved(latest)
        }

        if hasOrdinal {
            let recent = mostRecentTaskResults.filter { entry in
                entry.artifact.role != .internalIntermediate && entry.artifact.isAvailableLocally &&
                    (kindMention == nil || Self.matches(kindMention!, entry.artifact.kind)) &&
                    (agentMention == nil || entry.producingAgent == agentMention) &&
                    (operationFilter == nil || operationFilter!(entry.operation)) &&
                    (dateFilter == nil || dateFilter!(entry.createdAt))
            }
            let ordinal = tokens.contains("second") || tokens.contains("2nd") ? 2 :
                (tokens.contains("third") || tokens.contains("3rd") ? 3 : 1)
            guard recent.count >= ordinal else {
                return .clarify("I don't have a matching \(Self.ordinalName(ordinal)) result from the most recent task. Attach the file or choose one of the recent results.")
            }
            return .resolved(recent[ordinal - 1].artifact)
        }

        guard !candidates.isEmpty else { return .clarify("I couldn't find a matching recent Kio result. Attach the file you mean.") }
        if latestReference { return .resolved(candidates.last!.artifact) }
        if candidates.count == 1 { return .resolved(candidates[0].artifact) }
        let choices = candidates.suffix(4).reversed().enumerated().map { index, entry in
            "\(index + 1). \(entry.artifact.displayName)"
        }.joined(separator: "\n")
        return .clarify("Which result did you mean?\n\(choices)")
    }

    private static func mentionedKind(in tokens: Set<String>) -> ArtifactKind? {
        if tokens.contains("pdf") { return .pdf }
        if tokens.contains("csv") || tokens.contains("spreadsheet") || tokens.contains("table") { return .csv }
        if tokens.contains("image") || tokens.contains("photo") || tokens.contains("picture") || tokens.contains("screenshot") { return .image }
        if tokens.contains("video") { return .video }
        if tokens.contains("audio") { return .audio }
        if tokens.contains("patch") || tokens.contains("diff") { return .patch }
        if tokens.contains("text") || tokens.contains("document") || tokens.contains("markdown") { return .text }
        return nil
    }

    private static func matches(_ requested: ArtifactKind, _ actual: ArtifactKind) -> Bool {
        requested == actual || (requested == .csv && actual == .table)
    }

    private static func operationFilter(in tokens: Set<String>) -> ((ToolOperation?) -> Bool)? {
        if tokens.contains("compressed") || tokens.contains("compress") || tokens.contains("compression") {
            return { value in value.map { [.compressPDF, .compressImage, .compressVideo].contains($0) } ?? false }
        }
        if tokens.contains("receipt") { return { $0 == .extractReceipt }
        }
        if tokens.contains("ocr") { return { value in value.map { [.ocrImage, .ocrPDFText].contains($0) } ?? false }
        }
        if tokens.contains("merged") || tokens.contains("merge") { return { value in value.map { [.mergePDFs, .mergeData].contains($0) } ?? false }
        }
        if tokens.contains("converted") || tokens.contains("convert") { return { value in value.map { [.convertImage, .csvToJSON, .jsonToCSV].contains($0) } ?? false }
        }
        return nil
    }

    private static func ordinalName(_ value: Int) -> String {
        switch value { case 1: "first"; case 2: "second"; default: "third" }
    }
}
