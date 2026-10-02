import Foundation
import KioCore

public enum OutputLocation {
    private static let access = OutputFolderAccess()

    public static func makeURL(for inputs: [ArtifactRef], baseName: String, fileExtension: String) throws -> URL {
        let candidate = try destinationFolder(for: inputs)
        let safeBase = sanitize(baseName)
        var suffix = 1
        while true {
            let stem = suffix == 1 ? safeBase : "\(safeBase)-\(suffix)"
            let path = candidate.appendingPathComponent(stem)
            let result = fileExtension.isEmpty ? path : path.appendingPathExtension(fileExtension)
            if !FileManager.default.fileExists(atPath: result.path) { return result }
            suffix += 1
        }
    }

    public static func makeURL(in folder: URL, baseName: String, fileExtension: String) throws -> URL {
        guard folder.isFileURL, (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              FileManager.default.isWritableFile(atPath: folder.path) else {
            throw KioFailure.invalidInput("Choose a writable destination folder.")
        }
        let safeBase = sanitize(baseName)
        var suffix = 1
        while true {
            let stem = suffix == 1 ? safeBase : "\(safeBase)-\(suffix)"
            let path = folder.appendingPathComponent(stem)
            let result = fileExtension.isEmpty ? path : path.appendingPathExtension(fileExtension)
            if !FileManager.default.fileExists(atPath: result.path) { return result }
            suffix += 1
        }
    }

    /// Returns a fresh, conflict-safe directory path alongside the inputs or in the selected output folder.
    public static func makeDirectoryURL(for inputs: [ArtifactRef], baseName: String) throws -> URL {
        let folder = try destinationFolder(for: inputs)
        let safeBase = sanitize(baseName)
        var suffix = 1
        while true {
            let stem = suffix == 1 ? safeBase : "\(safeBase)-\(suffix)"
            let result = folder.appendingPathComponent(stem, isDirectory: true)
            if !FileManager.default.fileExists(atPath: result.path) { return result }
            suffix += 1
        }
    }

    public static func makeDirectoryURL(inside folder: URL, name: String) throws -> URL {
        guard folder.isFileURL, (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              FileManager.default.isWritableFile(atPath: folder.path) else {
            throw KioFailure.invalidInput("Choose a writable destination folder.")
        }
        let safeBase = sanitize(name)
        var suffix = 1
        while true {
            let stem = suffix == 1 ? safeBase : "\(safeBase)-\(suffix)"
            let result = folder.appendingPathComponent(stem, isDirectory: true)
            if !FileManager.default.fileExists(atPath: result.path) { return result }
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

    public static var customFolderName: String? { access.customFolder()?.lastPathComponent }

    public static func setCustomFolder(_ folder: URL) throws {
        guard folder.isFileURL,
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw KioFailure.invalidInput("Choose an existing folder for Kio's output location.")
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw KioFailure.invalidInput("Kio can't write to that folder. Choose a folder with write access.")
        }
        try access.setCustomFolder(folder)
    }

    public static func restoreDefault() { access.clearCustomFolder() }

    public static func stopAccessingSelectedFolder() { access.stopAccessing() }

    public static var preferenceDescription: String {
        customFolderName ?? "Source folder or Downloads/Kio"
    }

    private static func defaultFolder() throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = downloads.appendingPathComponent("Kio", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func destinationFolder(for inputs: [ArtifactRef]) throws -> URL {
        try resolvedDestinationFolder(for: inputs, customFolder: access.customFolder(), defaultFolder: defaultFolder())
    }

    static func resolvedDestinationFolder(for inputs: [ArtifactRef], customFolder: URL?, defaultFolder: URL) throws -> URL {
        let fm = FileManager.default
        if let customFolder { return customFolder }
        let userArtifacts = inputs.filter { $0.role != .internalIntermediate }
        guard !userArtifacts.isEmpty else { return defaultFolder }
        let parents = Set(userArtifacts.map { $0.fileURL.deletingLastPathComponent().standardizedFileURL })
        if userArtifacts.allSatisfy({
            let inbox = $0.fileURL.deletingLastPathComponent()
            return inbox.lastPathComponent == "ClipboardInbox" && inbox.deletingLastPathComponent().lastPathComponent == "Kio"
        }) { return defaultFolder }
        if userArtifacts.allSatisfy({ $0.kind == .url }) { return defaultFolder }
        if parents.count == 1, let parent = parents.first, fm.isWritableFile(atPath: parent.path) { return parent }
        return defaultFolder
    }

    private static func sanitize(_ value: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\?%*|\"<>"))
        let clean = value.components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        return clean.isEmpty ? "Kio-Output" : String(clean.prefix(96))
    }
}

private final class OutputFolderAccess: @unchecked Sendable {
    private let lock = NSLock()
    private let key = "kio.customOutputFolderBookmark"
    private var activeURL: URL?
    private var startedSecurityScope = false

    func customFolder() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let activeURL, FileManager.default.fileExists(atPath: activeURL.path),
           FileManager.default.isWritableFile(atPath: activeURL.path) {
            return activeURL
        }
        stopAccessingLocked()
        guard let bookmark = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        let resolved: URL
        do {
            resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            do {
                resolved = try URL(resolvingBookmarkData: bookmark, options: [],
                                   relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                UserDefaults.standard.removeObject(forKey: key)
                return nil
            }
        }
        guard resolved.isFileURL,
              (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        startedSecurityScope = resolved.startAccessingSecurityScopedResource()
        guard FileManager.default.isWritableFile(atPath: resolved.path) else {
            stopAccessingLocked()
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        activeURL = resolved
        if stale, let refreshed = Self.bookmark(for: resolved) {
            UserDefaults.standard.set(refreshed, forKey: key)
        }
        return resolved
    }

    func setCustomFolder(_ folder: URL) throws {
        guard let bookmark = Self.bookmark(for: folder) else {
            throw KioFailure.processing("Kio couldn't save access to that folder. Choose it again or use the default location.")
        }
        lock.lock()
        defer { lock.unlock() }
        stopAccessingLocked()
        UserDefaults.standard.set(bookmark, forKey: key)
        startedSecurityScope = folder.startAccessingSecurityScopedResource()
        activeURL = folder
    }

    func clearCustomFolder() {
        lock.lock()
        defer { lock.unlock() }
        stopAccessingLocked()
        UserDefaults.standard.removeObject(forKey: key)
    }

    func stopAccessing() {
        lock.lock()
        defer { lock.unlock() }
        stopAccessingLocked()
    }

    private func stopAccessingLocked() {
        if startedSecurityScope { activeURL?.stopAccessingSecurityScopedResource() }
        startedSecurityScope = false
        activeURL = nil
    }

    private static func bookmark(for folder: URL) -> Data? {
        (try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }
}
