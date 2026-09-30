import Foundation
import Darwin

public enum VoiceTemporaryFiles {
    public static func create(root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let path = root.appendingPathComponent("KioVoice-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return path
    }
    public static func removeAbandoned(root: URL = FileManager.default.temporaryDirectory,
                                       isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        guard let paths = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for path in paths where path.lastPathComponent.hasPrefix("KioVoice-") {
            guard let values = try? path.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            let parts = path.lastPathComponent.split(separator: "-")
            if parts.count >= 3, let pid = Int32(parts[1]), pid > 0 {
                if !isAlive(pid) { try? FileManager.default.removeItem(at: path) }
            } else if let date = attributes[.modificationDate] as? Date, Date().timeIntervalSince(date) > 86400 {
                // Legacy recorder directories have no PID; avoid touching a recent active capture.
                try? FileManager.default.removeItem(at: path)
            }
        }
    }
}
