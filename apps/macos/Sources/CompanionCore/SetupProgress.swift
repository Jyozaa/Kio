import Foundation

public enum KioSetupStage: String, Codable, CaseIterable, Sendable {
    case welcome = "WELCOME"
    case kioRuntime = "KIO_RUNTIME"
    case accessibility = "ACCESSIBILITY"
    case screenCapture = "SCREEN_CAPTURE"
    case inputMonitoring = "INPUT_MONITORING"
    case microphone = "MICROPHONE"
    case layaModel = "LAYA_MODEL"
    case voiceModel = "VOICE_MODEL"
    case selfTest = "SELF_TEST"
    case ready = "READY"

    public var isOptional: Bool {
        self == .microphone || self == .voiceModel
    }
}

public struct KioSetupProgress: Codable, Equatable, Sendable {
    public static let storageKey = "kio.setup.progress"
    public static let currentSchemaVersion = 1
    // Version 2 makes the global shortcut an explicit normal-mode requirement.
    // Existing completions are reopened once so the exact running build can be
    // granted Input Monitoring and the shortcut can be verified.
    public static let currentSetupVersion = 2

    public var schemaVersion: Int
    public var stage: KioSetupStage
    public var completedVersion: Int?
    public var skippedOptionalStages: Set<KioSetupStage>

    public init(
        schemaVersion: Int = currentSchemaVersion,
        stage: KioSetupStage = .welcome,
        completedVersion: Int? = nil,
        skippedOptionalStages: Set<KioSetupStage> = []
    ) {
        self.schemaVersion = schemaVersion
        self.stage = stage
        self.completedVersion = completedVersion
        self.skippedOptionalStages = skippedOptionalStages
    }

    public var needsFirstRun: Bool { completedVersion != Self.currentSetupVersion }

    public mutating func advance(to stage: KioSetupStage) {
        self.stage = stage
        skippedOptionalStages.remove(stage)
    }

    public mutating func skip(_ stage: KioSetupStage) {
        guard stage.isOptional else { return }
        skippedOptionalStages.insert(stage)
    }

    public mutating func markReady() {
        stage = .ready
        completedVersion = Self.currentSetupVersion
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data?) -> KioSetupProgress? {
        guard let data,
              let state = try? JSONDecoder().decode(KioSetupProgress.self, from: data),
              state.schemaVersion == currentSchemaVersion,
              KioSetupStage.allCases.contains(state.stage),
              state.skippedOptionalStages.allSatisfy(\.isOptional)
        else { return nil }
        return state
    }

    public static func load(from defaults: UserDefaults = .standard) -> KioSetupProgress {
        if let data = defaults.data(forKey: storageKey) {
            return decode(data) ?? KioSetupProgress()
        }
        var state = KioSetupProgress()
        // Migrate the previous unversioned completion marker without reopening setup.
        if defaults.bool(forKey: "kioSetupComplete") {
            state.markReady()
            state.save(to: defaults)
        }
        return state
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = encoded() else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
