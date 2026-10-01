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
    let plan: TaskPlan?
    let hadUnavailableActiveOutput: Bool
}

enum ConversationPersistence {
    private static let container: ModelContainer? = try? ModelContainer(for: StoredConversationEntry.self)
    private static let maximumEntries = 500
    private static let activeOutputKey = "kio.activeOutput"
    private static let activeOutputClearedKey = "kio.activeOutputWasCleared"

    static func restore() -> RestoredConversation? {
        guard let container else { return nil }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<StoredConversationEntry>(sortBy: [SortDescriptor(\.createdAt)])
        guard let entries = try? context.fetch(descriptor), !entries.isEmpty else { return nil }
        let items = entries.map { entry in
            ConversationItem(id: entry.id, speaker: entry.speaker, message: entry.message,
                             artifact: entry.artifactData.flatMap { try? JSONDecoder().decode(ArtifactRef.self, from: $0) },
                             createdAt: entry.createdAt, operation: entry.operationRawValue.flatMap(ToolOperation.init(rawValue:)))
        }
        let plan = UserDefaults.standard.data(forKey: "kio.previousPlan").flatMap { try? JSONDecoder().decode(TaskPlan.self, from: $0) }
        let latestOutputIndex = entries.lastIndex { $0.artifactData != nil }
        let latestOutput = latestOutputIndex.flatMap { index -> ArtifactRef? in
            guard let data = entries[index].artifactData else { return nil }
            return try? JSONDecoder().decode(ArtifactRef.self, from: data)
        }
        let hasUnrelatedRequestAfterOutput = latestOutputIndex.map { index in
            entries.suffix(from: index + 1).contains { entry in
                (entry.speaker == "You" || entry.speaker == "Phone") && entry.operationRawValue == nil
            }
        } ?? false
        let defaults = UserDefaults.standard
        let storedOutput = defaults.data(forKey: activeOutputKey).flatMap { try? JSONDecoder().decode(ArtifactRef.self, from: $0) }
        let restoredOutput: ArtifactRef?
        if defaults.bool(forKey: activeOutputClearedKey) {
            restoredOutput = nil
        } else if let storedOutput {
            restoredOutput = storedOutput
        } else if plan != nil, !hasUnrelatedRequestAfterOutput {
            // Migrate existing conversations that predate explicit active-result persistence.
            restoredOutput = latestOutput
        } else {
            restoredOutput = nil
        }
        let output = restoredOutput?.refreshedFromDisk()
        let operation = output == nil ? nil : latestOutputIndex.flatMap { ToolOperation(rawValue: entries[$0].operationRawValue ?? "") }
        return RestoredConversation(items: items, activeOutput: output, operation: operation, plan: output == nil ? nil : plan,
                                    hadUnavailableActiveOutput: restoredOutput != nil && output == nil)
    }

    static func saveActiveOutput(_ output: ArtifactRef?) {
        let defaults = UserDefaults.standard
        guard let output, let data = try? JSONEncoder().encode(output) else {
            defaults.removeObject(forKey: activeOutputKey)
            defaults.set(true, forKey: activeOutputClearedKey)
            return
        }
        defaults.set(data, forKey: activeOutputKey)
        defaults.set(false, forKey: activeOutputClearedKey)
    }

    static func saveLastPlan(_ plan: TaskPlan?) {
        guard let plan, let data = try? JSONEncoder().encode(plan) else {
            UserDefaults.standard.removeObject(forKey: "kio.previousPlan")
            return
        }
        UserDefaults.standard.set(data, forKey: "kio.previousPlan")
    }

    static func append(_ item: ConversationItem, operation: ToolOperation?) {
        guard let container else { return }
        let artifact = item.artifact.flatMap { try? JSONEncoder().encode($0) }
        let context = ModelContext(container)
        context.insert(StoredConversationEntry(id: item.id, speaker: item.speaker, message: item.message,
                                               artifactData: artifact, operationRawValue: operation?.rawValue, createdAt: item.createdAt))
        do { try context.save() }
        catch { return }
        let descriptor = FetchDescriptor<StoredConversationEntry>(sortBy: [SortDescriptor(\.createdAt)])
        if let entries = try? context.fetch(descriptor), entries.count > maximumEntries {
            entries.prefix(entries.count - maximumEntries).forEach(context.delete)
            try? context.save()
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: "kio.previousPlan")
        UserDefaults.standard.removeObject(forKey: activeOutputKey)
        UserDefaults.standard.removeObject(forKey: activeOutputClearedKey)
        guard let container else { return }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<StoredConversationEntry>()
        guard let entries = try? context.fetch(descriptor) else { return }
        entries.forEach(context.delete)
        try? context.save()
    }
}
