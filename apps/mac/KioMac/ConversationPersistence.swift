import Foundation
import KioCore
import SwiftData

@Model
final class StoredConversationEntry {
    @Attribute(.unique) var id: UUID
    var speaker: String
    var message: String
    var artifactData: Data?
    var operationRawValue: String?
    var createdAt: Date

    init(id: UUID, speaker: String, message: String, artifactData: Data?, operationRawValue: String?, createdAt: Date = .now) {
        self.id = id
        self.speaker = speaker
        self.message = message
        self.artifactData = artifactData
        self.operationRawValue = operationRawValue
        self.createdAt = createdAt
    }
}

struct RestoredConversation {
    let items: [ConversationItem]
    let activeOutput: ArtifactRef?
    let operation: ToolOperation?
}

enum ConversationPersistence {
    private static let container: ModelContainer? = try? ModelContainer(for: StoredConversationEntry.self)
    private static let maximumEntries = 500

    static func restore() -> RestoredConversation? {
        guard let container else { return nil }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<StoredConversationEntry>(sortBy: [SortDescriptor(\.createdAt)])
        guard let entries = try? context.fetch(descriptor), !entries.isEmpty else { return nil }
        let items = entries.map { entry in
            ConversationItem(id: entry.id, speaker: entry.speaker, message: entry.message, artifact: entry.artifactData.flatMap { try? JSONDecoder().decode(ArtifactRef.self, from: $0) })
        }
        let output = items.reversed().compactMap(\.artifact).first
        let operation = entries.reversed().compactMap { $0.operationRawValue }.first.flatMap(ToolOperation.init(rawValue:))
        return RestoredConversation(items: items, activeOutput: output, operation: operation)
    }

    static func append(_ item: ConversationItem, operation: ToolOperation?) {
        guard let container else { return }
        let artifact = item.artifact.flatMap { try? JSONEncoder().encode($0) }
        let context = ModelContext(container)
        context.insert(StoredConversationEntry(id: item.id, speaker: item.speaker, message: item.message, artifactData: artifact, operationRawValue: operation?.rawValue))
        do { try context.save() }
        catch { return }
        let descriptor = FetchDescriptor<StoredConversationEntry>(sortBy: [SortDescriptor(\.createdAt)])
        if let entries = try? context.fetch(descriptor), entries.count > maximumEntries {
            entries.prefix(entries.count - maximumEntries).forEach(context.delete)
            try? context.save()
        }
    }

    static func clear() {
        guard let container else { return }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<StoredConversationEntry>()
        guard let entries = try? context.fetch(descriptor) else { return }
        entries.forEach(context.delete)
        try? context.save()
    }
}
