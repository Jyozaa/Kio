import CryptoKit
import Foundation
import KioCore
import KioModel
import os
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
    public static let maximumOutputBytes = 512 * 1_024
    public static let maximumFormats = 512

    public static func decode(_ data: Data, remoteURL: URL) throws -> ReelInspectionInfo {
        guard data.count <= maximumOutputBytes else {
            throw KioFailure.verification("Reel received too much media metadata to inspect safely.")
        }
        guard !data.isEmpty else { throw KioFailure.verification("Reel didn't receive media details from this source.") }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let trimmedData = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: trimmedData) as? [String: Any] else {
            throw KioFailure.verification("Reel couldn't decode yt-dlp's media details.")
        }
        let title = ReelMediaRouter.safeTitle(json["title"] as? String ?? "Online media")
        let rawDuration = (json["duration"] as? NSNumber)?.doubleValue
        let duration = rawDuration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let formats = Array((json["formats"] as? [[String: Any]] ?? []).prefix(maximumFormats))
        let qualities = ReelMediaRouter.normalizedQualities(formats.map { ($0["height"] as? NSNumber)?.intValue })
        let containers = Array(Set(formats.compactMap { ($0["ext"] as? String)?.lowercased() }
            .filter { ["mp4", "webm", "mkv", "mov"].contains($0) })).sorted()
        let audioAvailable = (json["audio_ext"] as? String).map { !$0.isEmpty && $0.lowercased() != "none" } == true
            || formats.contains { ($0["acodec"] as? String).map { $0 != "none" } == true }
        let liveValue = json["is_live"] as? Bool
            ?? (json["is_live"] as? String).flatMap { ["true": true, "false": false][$0.lowercased()] }
        return ReelInspectionInfo(remoteURL: remoteURL.absoluteString, title: title, durationSeconds: duration,
                                  source: json["extractor_key"] as? String ?? remoteURL.host ?? "Unknown",
                                  isLive: liveValue == true,
                                  qualities: qualities, videoFormats: containers, audioAvailable: audioAvailable)
    }
}

public struct ReelBoundedProcessOutput: Sendable, Equatable {
    public let data: Data
    public let byteCount: Int
    public let truncated: Bool

    public init(data: Data, byteCount: Int, truncated: Bool) {
        self.data = data
        self.byteCount = byteCount
        self.truncated = truncated
    }
}

/// Stores only a bounded prefix while continuing to count and drain all process output.
public struct ReelProcessOutputAccumulator: Sendable, Equatable {
    public let maximumBytes: Int
    private var data = Data()
    private var byteCount = 0
    private var truncated = false

    public init(maximumBytes: Int) { self.maximumBytes = max(0, maximumBytes) }

    public mutating func append(_ chunk: Data) {
        byteCount = byteCount.addingReportingOverflow(chunk.count).overflow ? Int.max : byteCount + chunk.count
        let remaining = max(0, maximumBytes - data.count)
        if remaining > 0 { data.append(chunk.prefix(remaining)) }
        if chunk.count > remaining { truncated = true }
    }

    public var output: ReelBoundedProcessOutput {
        ReelBoundedProcessOutput(data: data, byteCount: byteCount, truncated: truncated)
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
    public static let inspectionJSONTemplate = #"{"title":%(title|"Online media")j,"duration":%(duration|null)j,"extractor_key":%(extractor_key|"")j,"is_live":%(is_live|false)j,"audio_ext":%(audio_ext|null)j,"formats":%(formats.:.{height,ext,acodec,vcodec}|[])j}"#

    public static func inspection(url: URL, denoURL: URL = ReelRuntime.denoURL) throws -> [String] {
        guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else {
            throw KioFailure.invalidInput("Reel's media inspection URL must use HTTP or HTTPS.")
        }
        return ["--no-playlist", "--no-warnings", "--no-progress", "--ignore-config", "--no-plugin-dirs",
                "--no-remote-components", "--no-cache-dir", "--no-cookies", "--no-cookies-from-browser",
                "--ignore-no-formats-error", "--js-runtimes", "deno:\(denoURL.path)", "--skip-download",
                "--print", inspectionJSONTemplate, url.absoluteString]
    }

    public static func ytDlp(operation: ToolOperation, url: URL, outputTemplate: String, quality: String?, format: String?,
                             ffmpegDirectory: URL, denoURL: URL = ReelRuntime.denoURL) throws -> [String] {
        guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http",
              outputTemplate.hasPrefix("/"), outputTemplate.count <= 2_000,
              quality.map(qualities.contains) ?? true else { throw KioFailure.invalidInput("Reel's media command contained an unsupported typed option.") }
        if operation == .downloadRemoteAudio {
            guard format.map(audioFormats.contains) ?? true else { throw KioFailure.invalidInput("Choose MP3, M4A, WAV, or FLAC for audio output.") }
        } else if operation == .downloadRemoteVideo || operation == .downloadRemoteLive {
            guard format.map(videoFormats.contains) ?? true else { throw KioFailure.invalidInput("Choose MP4, WebM, MKV, or MOV for video output.") }
        }
        var values = ["--no-playlist", "--no-warnings", "--no-progress", "--ignore-config", "--no-plugin-dirs",
                      "--no-remote-components", "--js-runtimes", "deno:\(denoURL.path)",
                      "-o", outputTemplate, "--ffmpeg-location", ffmpegDirectory.path]
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

public struct ReelRuntimeComponent: Decodable, Sendable, Identifiable {
    public let id: String
    public let version: String
    public let architecture: String
    public let upstreamURL: URL
    public let artifactURL: URL
    public let sha256: String
    public let license: String
    public let relativePath: String
}

public struct ReelRuntimeWheel: Decodable, Sendable {
    public let name: String
    public let version: String
    public let filename: String
    public let url: URL
    public let sha256: String
    public let license: String
}

public struct ReelRuntimeManifest: Decodable, Sendable {
    public let architecture: String
    public let components: [ReelRuntimeComponent]
    public let pythonVersion: String
    public let wheels: [ReelRuntimeWheel]

    public static let bundled: ReelRuntimeManifest? = {
        guard let url = Bundle.module.url(forResource: "ReelRuntime", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ReelRuntimeManifest.self, from: data)
    }()

    public func component(_ id: String) -> ReelRuntimeComponent? {
        components.first { $0.id == id }
    }
}

public enum ReelRuntime {
    public static var bundleURL: URL {
        Bundle.main.resourceURL?.appendingPathComponent("Reel", isDirectory: true)
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Reel", isDirectory: true)
    }

    public static func url(for componentID: String, in root: URL = bundleURL,
                           manifest: ReelRuntimeManifest? = .bundled) -> URL? {
        guard let component = manifest?.component(componentID) else { return nil }
        return root.appending(path: component.relativePath)
    }

    public static var ytDlpURL: URL { url(for: "yt-dlp") ?? bundleURL.appendingPathComponent("yt-dlp") }
    public static var denoURL: URL { url(for: "deno") ?? bundleURL.appendingPathComponent("deno") }
    public static var ffmpegURL: URL { url(for: "ffmpeg") ?? bundleURL.appendingPathComponent("ffmpeg/bin/ffmpeg") }
    public static var ffprobeURL: URL { url(for: "ffprobe") ?? bundleURL.appendingPathComponent("ffmpeg/bin/ffprobe") }
    public static var pythonURL: URL { url(for: "python") ?? bundleURL.appendingPathComponent("streamlink/python/bin/python3.12") }
    public static var streamlinkPackagesURL: URL { url(for: "streamlink") ?? bundleURL.appendingPathComponent("streamlink/site-packages") }

    public static func isReady(in root: URL = bundleURL, manifest: ReelRuntimeManifest? = .bundled) -> Bool {
        guard let manifest else { return false }
        let required = ["yt-dlp", "deno", "ffmpeg", "ffprobe", "python", "streamlink"]
        return required.allSatisfy { id in
            guard let path = url(for: id, in: root, manifest: manifest) else { return false }
            return FileManager.default.isExecutableFile(atPath: path.path)
                || (id == "streamlink" && FileManager.default.fileExists(atPath: path.appendingPathComponent("streamlink_cli/main.py").path))
        }
    }

    public static var diagnostics: [(name: String, version: String, available: Bool)] {
        guard let manifest = ReelRuntimeManifest.bundled else { return [("Media runtime", "Manifest missing", false)] }
        return manifest.components.map { component in
            let path = bundleURL.appending(path: component.relativePath)
            let available = component.id == "streamlink"
                ? FileManager.default.fileExists(atPath: path.appendingPathComponent("streamlink_cli/main.py").path)
                : component.id == "lame"
                ? FileManager.default.fileExists(atPath: path.path)
                : FileManager.default.isExecutableFile(atPath: path.path)
            return (component.id, component.version, available)
        }
    }
}

/// Compatibility facade for older call sites; this only reads the app bundle and never installs helpers.
public enum ReelHelperManager {
    public static var directory: URL { ReelRuntime.bundleURL }
    fileprivate static var streamlinkPackagesDirectory: URL { ReelRuntime.streamlinkPackagesURL }
    fileprivate static let streamlinkBootstrap = "import sys; sys.path.insert(0, sys.argv.pop(1)); from streamlink_cli.main import main; raise SystemExit(main())"
    public static let pythonRuntimeVersion = ReelRuntimeManifest.bundled?.component("python")?.version ?? "3.12.14"
    public static let pythonRuntime: ReelHelperInfo = info("python")
    public static let helpers: [ReelHelperInfo] = ReelRuntimeManifest.bundled?.components.map(info) ?? []

    private static func info(_ component: ReelRuntimeComponent) -> ReelHelperInfo {
        ReelHelperInfo(id: component.id, version: component.version, license: component.license,
                       releaseURL: component.artifactURL, sha256: component.sha256,
                       architecture: component.architecture,
                       installName: URL(fileURLWithPath: component.relativePath).lastPathComponent)
    }

    private static func info(_ id: String) -> ReelHelperInfo {
        guard let component = ReelRuntimeManifest.bundled?.component(id) else {
            return ReelHelperInfo(id: id, version: "unavailable", license: "not bundled", releaseURL: URL(fileURLWithPath: "/"),
                                  sha256: "", architecture: "", installName: id)
        }
        return info(component)
    }

    public static func isPrepared(_ name: String) -> Bool {
        if name == "gallery-dl" { return false }
        switch name {
        case "yt-dlp": return FileManager.default.isExecutableFile(atPath: ReelRuntime.ytDlpURL.path)
        case "deno": return FileManager.default.isExecutableFile(atPath: ReelRuntime.denoURL.path)
        case "ffmpeg": return FileManager.default.isExecutableFile(atPath: ReelRuntime.ffmpegURL.path)
        case "ffprobe": return FileManager.default.isExecutableFile(atPath: ReelRuntime.ffprobeURL.path)
        case "streamlink": return FileManager.default.isExecutableFile(atPath: ReelRuntime.pythonURL.path)
            && FileManager.default.fileExists(atPath: ReelRuntime.streamlinkPackagesURL.appendingPathComponent("streamlink_cli/main.py").path)
        default: return false
        }
    }

    public static var managedPython: URL? { isPrepared("streamlink") ? ReelRuntime.pythonURL : nil }

    public static func matchesSHA256(_ data: Data, expected: String) -> Bool {
        guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined().caseInsensitiveCompare(expected) == .orderedSame
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
        guard ReelHelperManager.isPrepared("yt-dlp") else { throw KioFailure.verification("Reel's bundled media runtime is missing or damaged. Reinstall Kio to restore it.") }
        let output = try await runHelper(name: "yt-dlp", arguments: ReelCommandBuilder.inspection(url: url),
                                         maximumStdoutBytes: ReelInspectionDecoder.maximumOutputBytes)
        guard !output.truncated else {
            throw KioFailure.verification("Reel received too much media metadata to inspect safely.")
        }
        guard !output.data.isEmpty else {
            throw KioFailure.verification("Reel didn't receive media details from this source.")
        }
        let info = try ReelInspectionDecoder.decode(output.data, remoteURL: url)
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
        if operation == .downloadRemoteGallery {
            throw KioFailure.unsupported("Gallery downloads are unavailable in this build. The optional gallery-dl component is GPL-2.0-only and the Kio repository does not currently declare a compatible redistribution license. Video and direct-media downloads remain bundled and ready.")
        }
        else if operation == .downloadRemoteLive && ReelHelperManager.isPrepared("streamlink") { helper = "streamlink" }
        else if backend == .streamlink && ReelHelperManager.isPrepared("streamlink") { helper = "streamlink" }
        else { helper = "yt-dlp" }
        guard ReelHelperManager.isPrepared(helper) else {
            throw KioFailure.verification("Reel's bundled \(helper) runtime is missing or damaged. Reinstall Kio to restore it.")
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
                                                    ffmpegDirectory: ReelRuntime.ffmpegURL.deletingLastPathComponent())
            }
            let helperOutput = try await runHelper(name: helper, arguments: args, maximumStdoutBytes: 64 * 1_024)
            if helperOutput.truncated {
                Self.logger.info("Download helper output truncated after \(helperOutput.byteCount, privacy: .public) bytes; completed files remain authoritative.")
            }
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

    private static let logger = Logger(subsystem: "app.kio.mac", category: "Reel")

    private static func runHelper(name: String, arguments: [String], maximumStdoutBytes: Int) async throws -> ReelBoundedProcessOutput {
        try Task.checkCancellation()
        let executable: URL
        let processArguments: [String]
        if name == "streamlink" {
            guard ReelHelperManager.isPrepared(name), let python = ReelHelperManager.managedPython else {
                throw KioFailure.unsupported("Kio's pinned Python runtime or Streamlink helper isn't ready.")
            }
            executable = python
            processArguments = ["-B", "-I", "-c", ReelHelperManager.streamlinkBootstrap,
                                ReelHelperManager.streamlinkPackagesDirectory.path] + arguments
        } else {
            switch name {
            case "yt-dlp": executable = ReelRuntime.ytDlpURL
            case "deno": executable = ReelRuntime.denoURL
            case "ffmpeg": executable = ReelRuntime.ffmpegURL
            case "ffprobe": executable = ReelRuntime.ffprobeURL
            default: throw KioFailure.unsupported("Reel does not recognize this bundled helper.")
            }
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
        let outputTask = Task.detached { Self.readBounded(outputPipe.fileHandleForReading, maximumBytes: maximumStdoutBytes) }
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
        let errorOutput = await errorTask.value
        let output = await outputTask.value
        logger.info("Helper \(name, privacy: .public) exited with status \(process.terminationStatus, privacy: .public); stdout bytes=\(output.byteCount, privacy: .public), truncated=\(output.truncated, privacy: .public), stderr bytes=\(errorOutput.byteCount, privacy: .public), stderr truncated=\(errorOutput.truncated, privacy: .public).")
        let detail = String(data: errorOutput.data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            switch ReelHelperFailureKind.classify(detail) {
            case .drmProtected: throw KioFailure.unsupported("This source is DRM-protected; Reel doesn't bypass DRM.")
            case .authenticationRequired: throw KioFailure.unsupported("This source requires account authentication. Reel doesn't read browser cookies or pass login credentials.")
            case .processFailure: throw KioFailure.processing("Reel's verified helper couldn't complete this request.")
            }
        }
        return output
    }

    private static func readBounded(_ handle: FileHandle, maximumBytes: Int) -> ReelBoundedProcessOutput {
        var result = ReelProcessOutputAccumulator(maximumBytes: maximumBytes)
        while true {
            let chunk = handle.readData(ofLength: 16_384)
            if chunk.isEmpty { break }
            result.append(chunk)
        }
        return result.output
    }

    private static func writeInspection(_ info: ReelInspectionInfo, input: ArtifactRef) throws -> ArtifactRef {
        try FileManager.default.createDirectory(at: ReelInspectionStore.directory, withIntermediateDirectories: true)
        let name = ReelMediaRouter.safeTitle(info.title) + "-inspection"
        let url = try OutputLocation.makeURL(in: ReelInspectionStore.directory, baseName: name, fileExtension: "kio-reel-info")
        try JSONEncoder().encode(info).write(to: url, options: .atomic)
        return try ArtifactRef.inspect(url, parentID: input.id)
    }
}
