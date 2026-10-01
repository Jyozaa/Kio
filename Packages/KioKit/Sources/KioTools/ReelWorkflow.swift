import CryptoKit
import Foundation
import KioCore
import KioModel
import ZIPFoundation

public enum ReelBackend: String, Sendable, Equatable {
    case directHTTP, ytDlp, streamlink, galleryDL
}

public enum ReelMediaRouter {
    public static func backend(for url: URL, helperDirectory: URL = ReelHelperManager.directory, availableHelpers: Set<String>? = nil) -> ReelBackend {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "m4v", "mov", "webm", "mp3", "m4a", "wav", "flac", "jpg", "jpeg", "png", "webp", "heic"].contains(ext) { return .directHTTP }
        if ["m3u8", "mpd"].contains(ext) || (url.host ?? "").localizedCaseInsensitiveContains("twitch") {
            let prepared = availableHelpers?.contains("streamlink") ?? ReelHelperManager.isPrepared("streamlink")
            return prepared ? .streamlink : .ytDlp
        }
        if ["gallery", "album"].contains(where: url.path.lowercased().contains) || (url.host ?? "").contains("imgur.com") {
            let prepared = availableHelpers?.contains("gallery-dl")
                ?? FileManager.default.isExecutableFile(atPath: helperDirectory.appendingPathComponent("gallery-dl").path)
            return prepared ? .galleryDL : .ytDlp
        }
        return .ytDlp
    }

    public static func safeURL(_ url: URL) throws -> URL {
        try ScoutURLPolicy.publicHTTPURL(url.absoluteString, resolveDNS: true)
    }

    public static func normalizedQualities(_ values: [Int?]) -> [String] {
        let available = Set(values.compactMap { $0 }.filter { $0 > 0 })
        let standard = [2160, 1440, 1080, 720, 480, 360].filter(available.contains).map { "\($0)p" }
        return ["best"] + standard
    }

    public static func safeTitle(_ title: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\?%*|\"<>"))
        let clean = title.components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        return String((clean.isEmpty ? "Reel-Download" : clean).prefix(96))
    }

    public static func isPreparedBinary(_ name: String, in directory: URL) -> Bool {
        guard ["yt-dlp", "gallery-dl", "ffmpeg", "ffprobe"].contains(name) else { return false }
        return FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent(name).path)
    }
}

public enum ReelInspectionDecoder {
    public static func decode(_ data: Data, remoteURL: URL) throws -> ReelInspectionInfo {
        guard data.count <= 8_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KioFailure.verification("Reel received malformed media inspection data.")
        }
        let title = ReelMediaRouter.safeTitle(json["title"] as? String ?? "Online media")
        let rawDuration = (json["duration"] as? NSNumber)?.doubleValue
        let duration = rawDuration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let formats = json["formats"] as? [[String: Any]] ?? []
        let qualities = ReelMediaRouter.normalizedQualities(formats.map { ($0["height"] as? NSNumber)?.intValue })
        let containers = Array(Set(formats.compactMap { ($0["ext"] as? String)?.lowercased() }
            .filter { ["mp4", "webm", "mkv", "mov"].contains($0) })).sorted()
        let audioAvailable = (json["audio_ext"] as? String) != nil
            || formats.contains { ($0["acodec"] as? String).map { $0 != "none" } == true }
        return ReelInspectionInfo(remoteURL: remoteURL.absoluteString, title: title, durationSeconds: duration,
                                  source: json["extractor_key"] as? String ?? remoteURL.host ?? "Unknown",
                                  isLive: (json["is_live"] as? Bool) == true,
                                  qualities: qualities, videoFormats: containers, audioAvailable: audioAvailable)
    }
}

public enum ReelHelperFailureKind: Sendable, Equatable {
    case drmProtected
    case authenticationRequired
    case processFailure

    public static func classify(_ detail: String) -> Self {
        let lower = detail.lowercased()
        if lower.contains("drm") || lower.contains("widevine") || lower.contains("encrypted") { return .drmProtected }
        if lower.contains("login") || lower.contains("authentication") || lower.contains("sign in") { return .authenticationRequired }
        return .processFailure
    }
}

public enum ReelOutputPolicy {
    public static func scan(root: URL, maximumCount: Int, maximumBytes: Int64) throws -> [URL] {
        guard maximumCount > 0, maximumBytes > 0 else { throw KioFailure.invalidInput("Reel output limits must be positive.") }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])?.compactMap { $0 as? URL } ?? []
        var totalBytes: Int64 = 0
        var safe: [URL] = []
        for file in files {
            let resolvedPath = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(prefix), !file.lastPathComponent.hasPrefix(".") else { continue }
            let values = try? file.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                  let size = values?.fileSize, size > 0 else { continue }
            let next = totalBytes.addingReportingOverflow(Int64(size))
            guard !next.overflow, next.partialValue <= maximumBytes else {
                throw KioFailure.verification("Reel output exceeded its task size limit.")
            }
            totalBytes = next.partialValue
            safe.append(file)
        }
        guard safe.count <= maximumCount else {
            throw KioFailure.verification("Reel found more than \(maximumCount) outputs; nothing was exposed. Narrow the gallery or playlist first.")
        }
        return safe.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

public enum ReelTemporaryWorkspace {
    public static func withDirectory<T>(at directory: URL, operation: (URL) async throws -> T) async throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await operation(directory)
    }
}

public enum ReelCommandBuilder {
    private static let qualities: Set<String> = ["best", "2160p", "1440p", "1080p", "720p", "480p", "360p"]
    private static let videoFormats: Set<String> = ["mp4", "webm", "mkv", "mov"]
    private static let audioFormats: Set<String> = ["mp3", "m4a", "wav", "flac"]

    public static func ytDlp(operation: ToolOperation, url: URL, outputTemplate: String, quality: String?, format: String?, ffmpegDirectory: URL) throws -> [String] {
        guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http",
              outputTemplate.hasPrefix("/"), outputTemplate.count <= 2_000,
              quality.map(qualities.contains) ?? true else { throw KioFailure.invalidInput("Reel's media command contained an unsupported typed option.") }
        if operation == .downloadRemoteAudio {
            guard format.map(audioFormats.contains) ?? true else { throw KioFailure.invalidInput("Choose MP3, M4A, WAV, or FLAC for audio output.") }
        } else if operation == .downloadRemoteVideo || operation == .downloadRemoteLive {
            guard format.map(videoFormats.contains) ?? true else { throw KioFailure.invalidInput("Choose MP4, WebM, MKV, or MOV for video output.") }
        }
        var values = ["--no-playlist", "--no-warnings", "--no-progress", "--ignore-config", "-o", outputTemplate,
                      "--ffmpeg-location", ffmpegDirectory.path]
        if operation == .downloadRemoteAudio {
            values += ["-x", "--audio-format", format ?? "m4a"]
        } else if operation == .downloadRemoteSubtitles {
            values += ["--write-subs", "--write-auto-subs", "--skip-download", "--sub-langs", "all", "--sub-format", "vtt"]
        } else if operation == .downloadRemoteThumbnail {
            values += ["--write-thumbnail", "--skip-download"]
        } else if let quality, quality != "best" {
            let height = Int(quality.dropLast()) ?? 1080
            values += ["-f", "bestvideo[height<=\(height)]+bestaudio/best[height<=\(height)]"]
        }
        if let format, operation == .downloadRemoteVideo || operation == .downloadRemoteLive {
            values += ["--merge-output-format", format]
        }
        values.append(url.absoluteString)
        return values
    }

    public static func streamlink(url: URL, outputPath: String, quality: String = "best") throws -> [String] {
        guard (url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"),
              outputPath.hasPrefix("/"), outputPath.count <= 2_000,
              qualities.contains(quality) else { throw KioFailure.invalidInput("Reel's live stream command contained an unsupported typed option.") }
        let normalized = quality == "best" ? "best" : "\(quality.dropLast())p"
        return ["--force", "--output", outputPath, url.absoluteString, normalized]
    }
}

public struct ReelHelperInfo: Sendable, Identifiable {
    public let id: String
    public let version: String
    public let license: String
    public let releaseURL: URL
    public let sha256: String
    public let architecture: String
    public let installName: String
}

private struct ReelPythonWheelManifest: Decodable {
    struct Wheel: Decodable {
        let name: String
        let version: String
        let filename: String
        let url: URL
        let sha256: String
        let license: String
    }
    let version: String
    let python: String
    let wheels: [Wheel]
}

public enum ReelHelperManager {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kio/Helpers", isDirectory: true)
    }
    fileprivate static var streamlinkPackagesDirectory: URL { directory.appendingPathComponent("streamlink/site-packages", isDirectory: true) }
    private static var streamlinkVersionURL: URL { directory.appendingPathComponent("streamlink/version.txt") }
    public static let pythonRuntimeVersion = "3.12.14"
    private static let pythonRuntimeURL = URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.12.14%2B20260901-aarch64-apple-darwin-install_only_stripped.tar.gz")!
    private static let pythonRuntimeSHA256 = "81a359f1cfadd4da11766534c5913791cea55f26e1bb902cacd2a531bb1e4b2b"
    private static var pythonRuntimeDirectory: URL { directory.appendingPathComponent("python", isDirectory: true) }
    fileprivate static let streamlinkBootstrap = "import sys; sys.path.insert(0, sys.argv.pop(1)); from streamlink_cli.main import main; raise SystemExit(main())"
    public static let helpers: [ReelHelperInfo] = [
        ReelHelperInfo(id: "yt-dlp", version: "2026.08.19", license: "Unlicense",
                       releaseURL: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos")!,
                       sha256: "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202",
                       architecture: "Universal macOS executable", installName: "yt-dlp"),
        ReelHelperInfo(id: "gallery-dl", version: "1.32.14", license: "GPL-2.0-only",
                       releaseURL: URL(string: "https://github.com/gdl-org/builds/releases/download/2026.10.01/gallery-dl_macos")!,
                       sha256: "f5be48ba15215c3e31e3e7d1afc23d1c63e507210a3241bbbc74b38730e77fef",
                       architecture: "macOS build", installName: "gallery-dl"),
        ReelHelperInfo(id: "ffmpeg", version: "9.0.2", license: "GPL build (x264/x265 enabled)",
                       releaseURL: URL(string: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip")!,
                       sha256: "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924",
                       architecture: "Apple Silicon arm64", installName: "ffmpeg"),
        ReelHelperInfo(id: "ffprobe", version: "9.0.2", license: "GPL build (paired with FFmpeg)",
                       releaseURL: URL(string: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffprobe.zip")!,
                       sha256: "fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6",
                       architecture: "Apple Silicon arm64", installName: "ffprobe")
    ]
    public static let pythonRuntime = ReelHelperInfo(
        id: "Python runtime", version: pythonRuntimeVersion, license: "PSF-2.0",
        releaseURL: pythonRuntimeURL, sha256: pythonRuntimeSHA256,
        architecture: "Apple Silicon arm64 · CPython", installName: "python3.12"
    )

    public static func isPrepared(_ name: String) -> Bool {
        if name == "streamlink" {
            return (try? String(contentsOf: streamlinkVersionURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == "8.6.0"
                && FileManager.default.fileExists(atPath: streamlinkPackagesDirectory.appendingPathComponent("streamlink_cli/main.py").path)
                && managedPython != nil
        }
        return ReelMediaRouter.isPreparedBinary(name, in: directory)
    }

    public static func matchesSHA256(_ data: Data, expected: String) -> Bool {
        guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else { return false }
        return sha256(data).caseInsensitiveCompare(expected) == .orderedSame
    }

    /// Called only from the explicit Prepare Reel action. Files are verified before any
    /// executable bit is set or helper version is queried.
    public static func prepareAll(progress: @MainActor @Sendable (Double, String) -> Void = { _, _ in }) async throws {
        #if !arch(arm64)
        throw KioFailure.unsupported("This pinned helper set currently targets Apple Silicon (arm64).")
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await progress(0.02, "Preparing the pinned Reel helper set…")
        try await installBinary(helpers[0])
        await progress(0.18, "Verified yt-dlp 2026.08.19")
        try await installBinary(helpers[1])
        await progress(0.34, "Verified gallery-dl 1.32.14")
        try await installFFmpeg(helpers[2])
        await progress(0.54, "Verified FFmpeg 9.0.2")
        try await installFFprobe(helpers[3])
        await progress(0.68, "Verified FFprobe 9.0.2")
        try await installPythonRuntime()
        await progress(0.76, "Verified isolated Python \(pythonRuntimeVersion)")
        try await installStreamlink(progress: progress)
        try verifyVersion("yt-dlp", contains: "2026.08.19")
        try verifyVersion("gallery-dl", contains: "1.32.14")
        try verifyVersion("ffmpeg", contains: "9.0.2")
        try verifyVersion("ffprobe", contains: "9.0.2")
        try verifyStreamlink()
        await progress(1, "All Reel helpers passed version checks.")
    }

    private static func installStreamlink(progress: @MainActor @Sendable (Double, String) -> Void) async throws {
        guard let manifestURL = Bundle.module.url(forResource: "StreamlinkWheels", withExtension: "json"),
              let manifest = try? JSONDecoder().decode(ReelPythonWheelManifest.self, from: Data(contentsOf: manifestURL)),
              manifest.version == "8.6.0", manifest.python == "3.12", manifest.wheels.count == 20 else {
            throw KioFailure.verification("Kio's pinned Streamlink wheel manifest is missing or malformed.")
        }
        let stage = directory.appendingPathComponent(".streamlink-\(UUID().uuidString)", isDirectory: true)
        let sitePackages = stage.appendingPathComponent("site-packages", isDirectory: true)
        try FileManager.default.createDirectory(at: sitePackages, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        for (index, wheel) in manifest.wheels.enumerated() {
            try Task.checkCancellation()
            guard wheel.url.host == "files.pythonhosted.org", wheel.filename.hasSuffix(".whl"), wheel.sha256.count == 64 else {
                throw KioFailure.verification("A Streamlink wheel entry failed its host or manifest check.")
            }
            let (temporary, response) = try await URLSession.shared.download(from: wheel.url)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                  let size = try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= 16 * 1_024 * 1_024 else {
                throw KioFailure.processing("Couldn't download the pinned Streamlink dependency \(wheel.name).")
            }
            let data = try Data(contentsOf: temporary)
            guard matchesSHA256(data, expected: wheel.sha256) else {
                throw KioFailure.verification("The \(wheel.name) wheel checksum did not match Kio's pinned SHA-256. It was not installed.")
            }
            let archiveURL = stage.appendingPathComponent(wheel.filename)
            try data.write(to: archiveURL, options: .atomic)
            try extractPinnedWheel(archiveURL, to: sitePackages)
            try? FileManager.default.removeItem(at: archiveURL)
            await progress(0.76 + 0.22 * Double(index + 1) / Double(manifest.wheels.count),
                           "Verified Streamlink dependency \(index + 1) of \(manifest.wheels.count)…")
        }
        guard FileManager.default.fileExists(atPath: sitePackages.appendingPathComponent("streamlink_cli/main.py").path),
              FileManager.default.fileExists(atPath: sitePackages.appendingPathComponent("streamlink/__init__.py").path) else {
            throw KioFailure.verification("The verified Streamlink wheels did not create the expected module layout.")
        }
        let final = directory.appendingPathComponent("streamlink", isDirectory: true)
        let backup = directory.appendingPathComponent(".streamlink-\(UUID().uuidString).old", isDirectory: true)
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.moveItem(at: final, to: backup) }
        do {
            try FileManager.default.moveItem(at: stage, to: final)
            try Data("8.6.0\n".utf8).write(to: final.appendingPathComponent("version.txt"), options: .atomic)
            try? FileManager.default.removeItem(at: backup)
        } catch {
            try? FileManager.default.removeItem(at: final)
            if FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.moveItem(at: backup, to: final) }
            throw error
        }
    }

    private static func extractPinnedWheel(_ archiveURL: URL, to destination: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw KioFailure.verification("A pinned Streamlink wheel could not be opened as a ZIP archive.")
        }
        for entry in archive {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.hasPrefix("/"), !components.contains(".."), !entry.path.contains("\\"), entry.type != .symlink else {
                throw KioFailure.verification("A pinned Streamlink wheel contains an unsafe archive path.")
            }
            let output = destination.appending(path: entry.path)
            if entry.type == .directory {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try archive.extract(entry, to: output, skipCRC32: false)
            }
        }
    }

    fileprivate static var managedPython: URL? {
        ["install/bin/python3.12", "install/bin/python"]
            .map(pythonRuntimeDirectory.appendingPathComponent)
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static func installPythonRuntime() async throws {
        if let python = managedPython,
           (try? await runVersionProbe(python).contains(pythonRuntimeVersion)) == true { return }
        let stagingArchive = directory.appendingPathComponent(".python-\(UUID().uuidString).tar.gz")
        let stagingRoot = directory.appendingPathComponent(".python-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stagingArchive)
            try? FileManager.default.removeItem(at: stagingRoot)
        }
        let (download, response) = try await URLSession.shared.download(from: pythonRuntimeURL)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let size = try? download.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 40 * 1_024 * 1_024 else {
            throw KioFailure.processing("Couldn't download Kio's pinned Python runtime for Streamlink.")
        }
        let bytes = try Data(contentsOf: download)
        guard Self.matchesSHA256(bytes, expected: pythonRuntimeSHA256) else {
            throw KioFailure.verification("The Python runtime checksum did not match Kio's pinned SHA-256. It was not installed.")
        }
        try bytes.write(to: stagingArchive, options: .atomic)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let extractor = Process()
        extractor.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        extractor.arguments = ["-xzf", stagingArchive.path, "-C", stagingRoot.path]
        try extractor.run()
        extractor.waitUntilExit()
        let candidate = stagingRoot.appendingPathComponent("python")
        let extractedPython = candidate.appendingPathComponent("install/bin/python3.12")
        guard extractor.terminationStatus == 0,
              FileManager.default.isExecutableFile(atPath: extractedPython.path),
              (try? await runVersionProbe(extractedPython).contains(pythonRuntimeVersion)) == true else {
            throw KioFailure.verification("The checksum-verified Python archive didn't contain the expected runnable \(pythonRuntimeVersion) arm64 runtime.")
        }
        let backup = directory.appendingPathComponent(".python-\(UUID().uuidString).old", isDirectory: true)
        if FileManager.default.fileExists(atPath: pythonRuntimeDirectory.path) {
            try FileManager.default.moveItem(at: pythonRuntimeDirectory, to: backup)
        }
        do {
            try FileManager.default.moveItem(at: candidate, to: pythonRuntimeDirectory)
            try? FileManager.default.removeItem(at: backup)
        } catch {
            if FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.moveItem(at: backup, to: pythonRuntimeDirectory)
            }
            throw error
        }
    }

    private static func runVersionProbe(_ executable: URL) async throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile().prefix(256), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw KioFailure.verification("The pinned Python runtime failed its version check.") }
        return output
    }

    private static func verifyStreamlink() throws {
        guard isPrepared("streamlink"), let python = managedPython else {
            throw KioFailure.unsupported("Kio's pinned Python 3.12 runtime is required to prepare Streamlink.")
        }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-I", "-c", streamlinkBootstrap, streamlinkPackagesDirectory.path, "--version"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile().prefix(1_000), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, output.contains("8.6.0") else {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("streamlink", isDirectory: true))
            throw KioFailure.verification("The pinned Streamlink package failed its bundled Python version check.")
        }
    }

    private static func installBinary(_ helper: ReelHelperInfo) async throws {
        let staging = directory.appendingPathComponent(".\(helper.installName)-\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: staging) }
        let (temporary, response) = try await URLSession.shared.download(from: helper.releaseURL)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw KioFailure.processing("Couldn't download the pinned \(helper.id) helper release.")
        }
        let bytes = try Data(contentsOf: temporary)
        guard Self.matchesSHA256(bytes, expected: helper.sha256) else {
            throw KioFailure.verification("The \(helper.id) helper checksum did not match its pinned SHA-256. It was not installed.")
        }
        try bytes.write(to: staging, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        let final = directory.appendingPathComponent(helper.installName)
        let backup = directory.appendingPathComponent(".\(helper.installName)-\(UUID().uuidString).old")
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.moveItem(at: final, to: backup) }
        do { try FileManager.default.moveItem(at: staging, to: final); try? FileManager.default.removeItem(at: backup) }
        catch { if FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.moveItem(at: backup, to: final) }; throw error }
    }

    private static func installFFmpeg(_ helper: ReelHelperInfo) async throws {
        let staging = directory.appendingPathComponent(".ffmpeg-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: staging) }
        let (temporary, response) = try await URLSession.shared.download(from: helper.releaseURL)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { throw KioFailure.processing("Couldn't download pinned FFmpeg.") }
        let data = try Data(contentsOf: temporary)
        guard Self.matchesSHA256(data, expected: helper.sha256) else {
            throw KioFailure.verification("The FFmpeg checksum did not match its pinned SHA-256. It was not installed.")
        }
        try data.write(to: staging, options: .atomic)
        let unpacked = directory.appendingPathComponent(".ffmpeg-unpack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", staging.path, "-d", unpacked.path]
        try unzip.run(); unzip.waitUntilExit()
        let files = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []
        guard unzip.terminationStatus == 0,
              let executable = files.first(where: { $0.lastPathComponent == "ffmpeg" && FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw KioFailure.verification("The pinned FFmpeg archive didn't contain a runnable binary.")
        }
        try installExtracted(executable, name: "ffmpeg")
    }

    private static func installFFprobe(_ helper: ReelHelperInfo) async throws {
        let staging = directory.appendingPathComponent(".ffprobe-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: staging) }
        let (temporary, response) = try await URLSession.shared.download(from: helper.releaseURL)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { throw KioFailure.processing("Couldn't download pinned FFprobe.") }
        let data = try Data(contentsOf: temporary)
        guard Self.matchesSHA256(data, expected: helper.sha256) else {
            throw KioFailure.verification("The FFprobe checksum did not match its pinned SHA-256. It was not installed.")
        }
        try data.write(to: staging, options: .atomic)
        let unpacked = directory.appendingPathComponent(".ffprobe-unpack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        let unzip = Process(); unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); unzip.arguments = ["-q", staging.path, "-d", unpacked.path]
        try unzip.run(); unzip.waitUntilExit()
        let files = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []
        guard unzip.terminationStatus == 0,
              let executable = files.first(where: { $0.lastPathComponent == "ffprobe" && FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw KioFailure.verification("The pinned FFprobe archive didn't contain a runnable binary.")
        }
        try installExtracted(executable, name: "ffprobe")
    }

    private static func installExtracted(_ source: URL, name: String) throws {
        let destination = directory.appendingPathComponent(name)
        let candidate = directory.appendingPathComponent(".\(name)-\(UUID().uuidString).new")
        defer { try? FileManager.default.removeItem(at: candidate) }
        try FileManager.default.copyItem(at: source, to: candidate)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
        let backup = directory.appendingPathComponent(".\(name)-\(UUID().uuidString).old")
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: destination, to: backup) }
        do { try FileManager.default.moveItem(at: candidate, to: destination); try? FileManager.default.removeItem(at: backup) }
        catch { if FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.moveItem(at: backup, to: destination) }; throw error }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { byte in String(format: "%02x", Int(byte)) }.joined()
    }

    private static func verifyVersion(_ name: String, contains expected: String) throws {
        let process = Process()
        process.executableURL = directory.appendingPathComponent(name)
        process.arguments = ["--version"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, output.contains(expected) else {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            throw KioFailure.verification("The installed \(name) helper failed its version check.")
        }
    }
}

public enum ReelInspectionStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kio/ReelInspection", isDirectory: true).standardizedFileURL
    }
    public static func readInfo(from artifact: ArtifactRef) throws -> ReelInspectionInfo {
        guard artifact.fileURL.isFileURL,
              artifact.fileURL.pathExtension.lowercased() == "kio-reel-info",
              artifact.fileURL.deletingLastPathComponent().standardizedFileURL == directory,
              artifact.sizeBytes <= 32_000,
              let data = try? Data(contentsOf: artifact.fileURL),
              let info = try? JSONDecoder().decode(ReelInspectionInfo.self, from: data) else {
            throw KioFailure.invalidInput("This saved Reel inspection is unavailable or malformed.")
        }
        return info
    }
}

enum ReelWorkflow {
    static func execute(_ operation: ToolOperation, inputs: [ArtifactRef], arguments: ToolArguments) async throws -> [ArtifactRef] {
        guard inputs.count == 1, let input = inputs.first else { throw KioFailure.invalidInput("Reel works on one remote media URL at a time.") }
        let url: URL
        if input.kind == .url { url = try ScoutInputStore.readURL(from: input) }
        else {
            let info = try ReelInspectionStore.readInfo(from: input)
            guard let parsed = URL(string: info.remoteURL) else { throw KioFailure.invalidInput("The URL in this Reel inspection is invalid.") }
            url = parsed
        }
        _ = try ReelMediaRouter.safeURL(url)
        if operation == .inspectRemoteMedia { return [try await inspect(url, input: input)] }
        guard case .remoteMedia(let quality, let format) = arguments else { throw KioFailure.invalidInput("Choose a Reel quality and format.") }
        return try await download(operation, url: url, input: input, quality: quality, format: format)
    }

    private static func inspect(_ url: URL, input: ArtifactRef) async throws -> ArtifactRef {
        let backend = ReelMediaRouter.backend(for: url)
        guard backend != .directHTTP else {
            let ext = url.pathExtension.lowercased()
            let title = ReelMediaRouter.safeTitle(url.deletingPathExtension().lastPathComponent)
            return try writeInspection(ReelInspectionInfo(remoteURL: url.absoluteString, title: title,
                                                         durationSeconds: nil, source: url.host ?? "Direct URL", isLive: false,
                                                         qualities: ["best"], videoFormats: [ext].filter { ["mp4", "webm", "mkv", "mov"].contains($0) },
                                                         audioAvailable: ["mp3", "m4a", "wav", "flac"].contains(ext)), input: input)
        }
        guard ReelHelperManager.isPrepared("yt-dlp") else { throw KioFailure.unsupported("Reel needs its pinned media helper first. Open Settings → Reel and select Prepare Reel.") }
        let data = try await runHelper(name: "yt-dlp", arguments: ["--dump-single-json", "--skip-download", "--no-playlist", "--no-warnings", "--no-progress", "--ignore-config", url.absoluteString])
        let info = try ReelInspectionDecoder.decode(data, remoteURL: url)
        return try writeInspection(info, input: input)
    }

    private static func download(_ operation: ToolOperation, url: URL, input: ArtifactRef, quality: String?, format: String?) async throws -> [ArtifactRef] {
        let backend = ReelMediaRouter.backend(for: url)
        let sourceFormat = url.pathExtension.lowercased()
        let requestedFormatMatchesSource = format == nil || format == sourceFormat || (format == "jpeg" && sourceFormat == "jpg")
        let sourceIsAudio = ["mp3", "m4a", "wav", "flac"].contains(sourceFormat)
        if backend == .directHTTP && requestedFormatMatchesSource
            && ((operation == .downloadRemoteVideo && !sourceIsAudio) || (operation == .downloadRemoteAudio && sourceIsAudio)) {
            return [try await downloadDirect(url, input: input, requestedFormat: format)]
        }
        let helper: String
        if operation == .downloadRemoteGallery { helper = "gallery-dl" }
        else if operation == .downloadRemoteLive && ReelHelperManager.isPrepared("streamlink") { helper = "streamlink" }
        else if backend == .streamlink && ReelHelperManager.isPrepared("streamlink") { helper = "streamlink" }
        else { helper = "yt-dlp" }
        guard ReelHelperManager.isPrepared(helper) else {
            let extra = helper == "streamlink" ? "Streamlink can be installed from its official source and placed in the Kio Helpers folder." : "Use Settings → Reel → Prepare Reel to install the pinned helper."
            throw KioFailure.unsupported("Reel's \(helper) helper isn't prepared. \(extra)")
        }
        let parent = try OutputLocation.makeDirectoryURL(for: [input], baseName: "Kio-Reel-Tmp-\(UUID().uuidString)")
        return try await ReelTemporaryWorkspace.withDirectory(at: parent) { parent in
            let outputTemplate = parent.appendingPathComponent("media.%(ext)s").path
            let args: [String]
            if helper == "gallery-dl" {
                args = ["--no-mtime", "--directory", parent.path, "--filename", "{filename}", url.absoluteString]
            } else if helper == "streamlink" {
                args = try ReelCommandBuilder.streamlink(url: url, outputPath: parent.appendingPathComponent("media.ts").path)
            } else {
                args = try ReelCommandBuilder.ytDlp(operation: operation, url: url, outputTemplate: outputTemplate,
                                                    quality: quality, format: format,
                                                    ffmpegDirectory: ReelHelperManager.directory)
            }
            _ = try await runHelper(name: helper, arguments: args)
            try Task.checkCancellation()
            let produced = try outputFiles(in: parent, maximumCount: operation == .downloadRemoteGallery ? 100 : 8)
            guard let first = produced.first else { throw KioFailure.verification("Reel finished without a usable output file.") }
            if operation == .downloadRemoteGallery {
                let images = produced.filter { ["jpg", "jpeg", "png", "webp", "heic", "tif", "tiff", "bmp"].contains($0.pathExtension.lowercased()) }
                guard !images.isEmpty else { throw KioFailure.verification("Reel did not find any usable image files in that gallery.") }
                var outputs: [ArtifactRef] = []
                do {
                    for (index, file) in images.enumerated() {
                        try Task.checkCancellation()
                        let base = ReelMediaRouter.safeTitle(file.deletingPathExtension().lastPathComponent)
                        let output = try OutputLocation.makeURL(for: [input], baseName: String(format: "%03d-%@", index + 1, base), fileExtension: file.pathExtension)
                        try FileManager.default.moveItem(at: file, to: output)
                        outputs.append(try ArtifactRef.inspect(output, parentID: input.id))
                    }
                    return outputs
                } catch {
                    for output in outputs { try? FileManager.default.removeItem(at: output.fileURL) }
                    throw error
                }
            }
            let output = try OutputLocation.makeURL(for: [input], baseName: ReelMediaRouter.safeTitle(first.deletingPathExtension().lastPathComponent), fileExtension: first.pathExtension)
            try FileManager.default.moveItem(at: first, to: output)
            return [try ArtifactRef.inspect(output, parentID: input.id)]
        }
    }

    private static func outputFiles(in root: URL, maximumCount: Int) throws -> [URL] {
        try ReelOutputPolicy.scan(root: root, maximumCount: maximumCount, maximumBytes: 8 * 1_024 * 1_024 * 1_024)
    }

    private static func downloadDirect(_ url: URL, input: ArtifactRef, requestedFormat: String?) async throws -> ArtifactRef {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let finalURL = http.url, (try? ReelMediaRouter.safeURL(finalURL)) != nil else {
            throw KioFailure.processing("The direct media URL didn't return a safe public media response.")
        }
        let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= 8 * 1_024 * 1_024 * 1_024 else { throw KioFailure.verification("The direct media download was empty or exceeded the 8 GB limit.") }
        let ext = requestedFormat ?? url.pathExtension.lowercased()
        guard ["mp4", "m4v", "mov", "webm", "mp3", "m4a", "wav", "flac", "jpg", "jpeg", "png", "webp", "heic"].contains(ext) else {
            throw KioFailure.unsupported("Reel couldn't determine a safe file extension for this direct media URL.")
        }
        let output = try OutputLocation.makeURL(for: [input], baseName: ReelMediaRouter.safeTitle(url.deletingPathExtension().lastPathComponent), fileExtension: ext)
        try FileManager.default.copyItem(at: temporary, to: output)
        return try ArtifactRef.inspect(output, parentID: input.id)
    }

    private static func runHelper(name: String, arguments: [String]) async throws -> Data {
        try Task.checkCancellation()
        let executable: URL
        let processArguments: [String]
        if name == "streamlink" {
            guard ReelHelperManager.isPrepared(name), let python = ReelHelperManager.managedPython else {
                throw KioFailure.unsupported("Kio's pinned Python runtime or Streamlink helper isn't ready.")
            }
            executable = python
            processArguments = ["-I", "-c", ReelHelperManager.streamlinkBootstrap,
                                ReelHelperManager.streamlinkPackagesDirectory.path] + arguments
        } else {
            executable = ReelHelperManager.directory.appendingPathComponent(name)
            processArguments = arguments
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw KioFailure.unsupported("The pinned \(name) helper isn't prepared yet.") }
        }
        let process = Process(); let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = processArguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do { try process.run() } catch { throw KioFailure.processing("Reel couldn't start its verified helper: \(error.localizedDescription)") }
        let outputTask = Task.detached { Self.readBounded(outputPipe.fileHandleForReading, maximumBytes: 8_000_000) }
        let errorTask = Task.detached { Self.readBounded(errorPipe.fileHandleForReading, maximumBytes: 2_000) }
        do {
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(120))
            }
        } catch {
            if process.isRunning { process.terminate() }
            try? await Task.sleep(for: .milliseconds(250))
            if process.isRunning { process.interrupt() }
            _ = await outputTask.value
            _ = await errorTask.value
            throw CancellationError()
        }
        let detail = String(data: await errorTask.value, encoding: .utf8) ?? ""
        let outputData = await outputTask.value
        guard process.terminationStatus == 0 else {
            switch ReelHelperFailureKind.classify(detail) {
            case .drmProtected: throw KioFailure.unsupported("This source is DRM-protected; Reel doesn't bypass DRM.")
            case .authenticationRequired: throw KioFailure.unsupported("This source requires account authentication. Reel doesn't read browser cookies or pass login credentials.")
            case .processFailure: throw KioFailure.processing("Reel's verified helper couldn't complete this request. \(String(detail.prefix(240)))")
            }
        }
        guard outputData.count <= 8_000_000 else { throw KioFailure.verification("Reel helper metadata exceeded its 8 MB limit.") }
        return outputData
    }

    private static func readBounded(_ handle: FileHandle, maximumBytes: Int) -> Data {
        var result = Data()
        while true {
            let chunk = handle.readData(ofLength: 16_384)
            if chunk.isEmpty { break }
            if result.count < maximumBytes { result.append(chunk.prefix(maximumBytes - result.count)) }
        }
        return result
    }

    private static func writeInspection(_ info: ReelInspectionInfo, input: ArtifactRef) throws -> ArtifactRef {
        try FileManager.default.createDirectory(at: ReelInspectionStore.directory, withIntermediateDirectories: true)
        let name = ReelMediaRouter.safeTitle(info.title) + "-inspection"
        let url = try OutputLocation.makeURL(in: ReelInspectionStore.directory, baseName: name, fileExtension: "kio-reel-info")
        try JSONEncoder().encode(info).write(to: url, options: .atomic)
        return try ArtifactRef.inspect(url, parentID: input.id)
    }
}
