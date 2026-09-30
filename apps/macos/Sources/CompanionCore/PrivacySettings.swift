import Foundation

public struct PrivacySettings: Codable, Equatable {
    public init() {}
    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kio/config/privacy.json")
    }
    public static func load(from url: URL = fileURL) -> PrivacySettings {
        guard let data = try? Data(contentsOf: url), data.count <= 4096,
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }
    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
