import Foundation
import KioCore

public enum OutputLocation {
    public static func makeURL(for inputs: [ArtifactRef], baseName: String, fileExtension: String) throws -> URL {
        let fm = FileManager.default
        let parents = Set(inputs.map { $0.fileURL.deletingLastPathComponent().standardizedFileURL })
        let candidate: URL
        if parents.count == 1, let parent = parents.first, fm.isWritableFile(atPath: parent.path) {
            candidate = parent
        } else {
            let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
            candidate = downloads.appendingPathComponent("Kio", isDirectory: true)
            try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
        }
        let safeBase = sanitize(baseName)
        var suffix = 1
        while true {
            let stem = suffix == 1 ? safeBase : "\(safeBase)-\(suffix)"
            let path = candidate.appendingPathComponent(stem)
            let result = fileExtension.isEmpty ? path : path.appendingPathExtension(fileExtension)
            if !fm.fileExists(atPath: result.path) { return result }
            suffix += 1
        }
    }

    public static func temporaryURL(beside output: URL) -> URL {
        output.deletingLastPathComponent()
            .appendingPathComponent(".kio-\(UUID().uuidString)")
            .appendingPathExtension(output.pathExtension)
    }

    public static func commit(_ temporary: URL, to output: URL) throws {
        guard FileManager.default.fileExists(atPath: temporary.path) else {
            throw KioFailure.verification("The operation did not create an output file.")
        }
        guard (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw KioFailure.verification("The output file is empty.")
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: output)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func sanitize(_ value: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\?%*|\"<>"))
        let clean = value.components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        return clean.isEmpty ? "Kio-Output" : String(clean.prefix(96))
    }
}
