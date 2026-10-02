import CryptoKit
import Foundation
import KioCore
import KioModel
import os
import ZIPFoundation

public enum ReelBackend: String, Sendable, Equatable {
    case directHTTP, ytDlp, streamlink
}

public enum ReelMediaRouter {
    public static func backend(for url: URL, helperDirectory: URL = ReelHelperManager.directory, availableHelpers: Set<String>? = nil) -> ReelBackend {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "m4v", "mov", "webm", "mp3", "m4a", "wav", "flac", "jpg", "jpeg", "png", "webp", "heic"].contains(ext) { return .directHTTP }
        if ["m3u8", "mpd"].contains(ext) {
            let prepared = availableHelpers?.contains("streamlink") ?? ReelHelperManager.isPrepared("streamlink")
            return prepared ? .streamlink : .ytDlp
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
        guard ["yt-dlp", "ffmpeg", "ffprobe"].contains(name) else { return false }
        return FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent(name).path)
    }
}

public enum ReelRedirectPolicy {
    public static let maximumRedirects = 5

    public static func validateDestination(_ destination: URL?, redirectsFollowed: Int) throws -> URL {
        guard redirectsFollowed < maximumRedirects, let destination,
              ScoutURLPolicy.isHTTPURL(destination) else {
            throw KioFailure.invalidInput("The media URL redirected to an unsafe destination.")
        }
        try ScoutURLPolicy.validatePublicHost(destination.host ?? "")
        return destination
    }
}

private final class ReelDownloadTaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    func install(_ task: URLSessionDownloadTask) {
        lock.lock(); self.task = task; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
}

/// Download delegate validates each redirect before following it and enforces the
/// task byte cap while URLSession is still receiving data.
private final class BoundedReelDownloader: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var downloadedURL: URL?
    private var terminalError: Error?
    private var redirectCount = 0
    private let maximumBytes: Int64
    private let handle = ReelDownloadTaskHandle()

    init(maximumBytes: Int64) { self.maximumBytes = maximumBytes }

    static func download(_ url: URL, maximumBytes: Int64) async throws -> (URL, HTTPURLResponse) {
        let downloader = BoundedReelDownloader(maximumBytes: maximumBytes)
        return try await withTaskCancellationHandler {
            try await downloader.start(url)
        } onCancel: {
            downloader.handle.cancel()
        }
    }

    private func start(_ url: URL) async throws -> (URL, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 4 * 60 * 60
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            let task = session!.downloadTask(with: URLRequest(url: url))
            handle.install(task)
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        do {
            let safe = try ReelRedirectPolicy.validateDestination(request.url, redirectsFollowed: redirectCount)
            redirectCount += 1
            var validated = request
            validated.url = safe
            completionHandler(validated)
        } catch {
            terminalError = error
            completionHandler(nil)
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if response == nil, let http = downloadTask.response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                terminalError = KioFailure.processing("The media source returned an unsuccessful response.")
                downloadTask.cancel()
                return
            }
            do { try ScoutURLPolicy.validatePublicHost(http.url?.host ?? "") }
            catch { terminalError = error; downloadTask.cancel(); return }
            response = http
        }
        if let expected = downloadTask.response?.expectedContentLength, expected > maximumBytes {
            terminalError = KioFailure.verification("The media source is larger than Reel's 8 GB limit.")
            downloadTask.cancel()
            return
        }
        guard totalBytesWritten <= maximumBytes else {
            terminalError = KioFailure.verification("The media download exceeded Reel's 8 GB limit.")
            downloadTask.cancel()
            return
        }
        if totalBytesExpectedToWrite > maximumBytes {
            terminalError = KioFailure.verification("The media source is larger than Reel's 8 GB limit.")
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if response == nil, let http = downloadTask.response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                terminalError = KioFailure.processing("The media source returned an unsuccessful response.")
                return
            }
            do { try ScoutURLPolicy.validatePublicHost(http.url?.host ?? "") }
            catch { terminalError = error; return }
            response = http
        }
        if let expected = downloadTask.response?.expectedContentLength, expected > maximumBytes {
            terminalError = KioFailure.verification("The media source is larger than Reel's 8 GB limit.")
            return
        }
        let stable = FileManager.default.temporaryDirectory.appendingPathComponent("Kio-Reel-\(UUID().uuidString).download")
        do { try FileManager.default.copyItem(at: location, to: stable); downloadedURL = stable }
        catch { terminalError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let terminalError { finish(.failure(terminalError)); return }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { finish(.failure(CancellationError())) }
            else { finish(.failure(error)) }
            return
        }
        guard let downloadedURL, let response else {
            finish(.failure(KioFailure.verification("The direct media download did not produce a complete file.")))
            return
        }
        finish(.success((downloadedURL, response)))
    }

    private func finish(_ result: Result<(URL, HTTPURLResponse), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.finishTasksAndInvalidate()
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error):
            if let downloadedURL { try? FileManager.default.removeItem(at: downloadedURL) }
            continuation.resume(throwing: error)
        }
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

public enum ReelStreamlinkInspectionDecoder {
    public static let maximumOutputBytes = 256 * 1_024
    public static let maximumStreams = 128

    public static func decode(_ data: Data, remoteURL: URL) throws -> ReelInspectionInfo {
        guard !data.isEmpty, data.count <= maximumOutputBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = object["streams"] as? [String: Any], !streams.isEmpty,
              streams.count <= maximumStreams else {
            throw KioFailure.verification("Reel couldn't decode Streamlink's bounded media details.")
        }
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let title = ReelMediaRouter.safeTitle(metadata["title"] as? String
            ?? remoteURL.deletingPathExtension().lastPathComponent)
        let qualities = streams.keys.compactMap { key -> Int? in
            guard let match = key.range(of: #"(?i)(?:^|\D)(\d{3,4})p(?:$|\D)"#, options: .regularExpression) else { return nil }
            let value = key[match].filter(\.isNumber)
            return Int(value)
        }
        return ReelInspectionInfo(remoteURL: remoteURL.absoluteString, title: title, durationSeconds: nil,
                                  source: (object["plugin"] as? String)?.split(separator: ".").last.map(String.init)
                                    ?? remoteURL.host ?? "Unknown",
                                  isLive: false, qualities: ReelMediaRouter.normalizedQualities(qualities),
                                  videoFormats: ["mp4"], audioAvailable: true)
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
    public static func currentSize(root: URL, maximumBytes: Int64) throws -> Int64 {
        guard maximumBytes > 0 else { throw KioFailure.invalidInput("Reel output limits must be positive.") }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])?.compactMap { $0 as? URL } ?? []
        var totalBytes: Int64 = 0
        for file in files {
            let resolvedPath = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(prefix) else { continue }
            let values = try? file.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true, values?.isSymbolicLink != true, let size = values?.fileSize, size > 0 else { continue }
            let next = totalBytes.addingReportingOverflow(Int64(size))
            guard !next.overflow, next.partialValue <= maximumBytes else {
                throw KioFailure.verification("Reel stopped the transfer because its task size limit was reached.")
            }
            totalBytes = next.partialValue
        }
        return totalBytes
    }

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

    public static func streamlinkInspection(url: URL) throws -> [String] {
        guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else {
            throw KioFailure.invalidInput("Reel's media inspection URL must use HTTP or HTTPS.")
        }
        return ["--no-config", "--no-plugin-sideloading", "--json", url.absoluteString]
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
        return ["--no-config", "--no-plugin-sideloading", "--force", "--output", outputPath, url.absoluteString, normalized]
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
    public static var ffmpegURL: URL { BundledMediaRuntime.ffmpegURL }
    public static var ffprobeURL: URL { BundledMediaRuntime.ffprobeURL }
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

    public static func removeInfoIfInternal(_ artifact: ArtifactRef) {
        guard artifact.role == .internalIntermediate,
              artifact.fileURL.pathExtension.lowercased() == "kio-reel-info",
              artifact.fileURL.deletingLastPathComponent().standardizedFileURL == directory else { return }
        try? FileManager.default.removeItem(at: artifact.fileURL)
    }

    public static func prune(now: Date = .now, ttl: TimeInterval = 7 * 24 * 60 * 60, maximumCount: Int = 50) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
        let inspections = files.filter { $0.pathExtension.lowercased() == "kio-reel-info" }
            .compactMap { url -> (URL, Date)? in
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, modified)
            }.sorted { $0.1 > $1.1 }
        for (index, entry) in inspections.enumerated() where now.timeIntervalSince(entry.1) > ttl || index >= max(1, maximumCount) {
            try? FileManager.default.removeItem(at: entry.0)
        }
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
        do {
            let output = try await runHelper(name: "yt-dlp", arguments: ReelCommandBuilder.inspection(url: url),
                                             maximumStdoutBytes: ReelInspectionDecoder.maximumOutputBytes,
                                             maximumDurationSeconds: 180)
            guard !output.truncated else { throw KioFailure.verification("Reel received too much media metadata to inspect safely.") }
            let info = try ReelInspectionDecoder.decode(output.data, remoteURL: url)
            return try writeInspection(info, input: input)
        } catch {
            guard ReelHelperManager.isPrepared("streamlink"), !(error is CancellationError) else { throw error }
            let fallback = try await runHelper(name: "streamlink", arguments: ReelCommandBuilder.streamlinkInspection(url: url),
                                               maximumStdoutBytes: ReelStreamlinkInspectionDecoder.maximumOutputBytes,
                                               maximumDurationSeconds: 180)
            guard !fallback.truncated else { throw KioFailure.verification("Reel received too much Streamlink metadata to inspect safely.") }
            return try writeInspection(ReelStreamlinkInspectionDecoder.decode(fallback.data, remoteURL: url), input: input)
        }
    }

    private static func download(_ operation: ToolOperation, url: URL, input: ArtifactRef, quality: String?, format: String?) async throws -> [ArtifactRef] {
        let backend = ReelMediaRouter.backend(for: url)
        let sourceFormat = url.pathExtension.lowercased()
        let sourceIsAudio = ["mp3", "m4a", "wav", "flac"].contains(sourceFormat)
        let sourceIsVideo = ["mp4", "m4v", "mov", "webm", "mkv"].contains(sourceFormat)
        let canUseDirect = backend == .directHTTP
            && ((operation == .downloadRemoteVideo && sourceIsVideo) || (operation == .downloadRemoteAudio && (sourceIsAudio || sourceIsVideo)))
        if canUseDirect {
            let output = try await downloadDirect(url, input: input, operation: operation, requestedFormat: format, quality: quality)
            ReelInspectionStore.removeInfoIfInternal(input)
            return [output]
        }
        let helper: String
        if operation == .downloadRemoteLive && ReelHelperManager.isPrepared("streamlink") { helper = "streamlink" }
        else if backend == .streamlink && ReelHelperManager.isPrepared("streamlink") { helper = "streamlink" }
        else { helper = "yt-dlp" }
        guard ReelHelperManager.isPrepared(helper) else {
            throw KioFailure.verification("Reel's bundled \(helper) runtime is missing or damaged. Reinstall Kio to restore it.")
        }
        let parent = try OutputLocation.makeDirectoryURL(for: [input], baseName: "Kio-Reel-Tmp-\(UUID().uuidString)")
        return try await ReelTemporaryWorkspace.withDirectory(at: parent) { parent in
            let outputTemplate = parent.appendingPathComponent("media.%(ext)s").path
            func arguments(for helper: String) throws -> [String] {
                if helper == "streamlink" {
                    return try ReelCommandBuilder.streamlink(url: url, outputPath: parent.appendingPathComponent("media.ts").path,
                                                             quality: quality ?? "best")
                }
                return try ReelCommandBuilder.ytDlp(operation: operation, url: url, outputTemplate: outputTemplate,
                                                    quality: quality, format: format,
                                                    ffmpegDirectory: ReelRuntime.ffmpegURL.deletingLastPathComponent())
            }
            var helperOutput: ReelBoundedProcessOutput
            do {
                helperOutput = try await runHelper(name: helper, arguments: arguments(for: helper), maximumStdoutBytes: 64 * 1_024,
                                                   monitorOutputDirectory: parent, maximumOutputBytes: BundledMediaRuntime.maximumMediaBytes)
            } catch {
                let canFallback = helper == "yt-dlp" && [ToolOperation.downloadRemoteVideo, .downloadRemoteAudio, .downloadRemoteLive].contains(operation)
                    && ReelHelperManager.isPrepared("streamlink") && !(error is CancellationError)
                guard canFallback else { throw error }
                for partial in try outputFiles(in: parent, maximumCount: 8) { try? FileManager.default.removeItem(at: partial) }
                helperOutput = try await runHelper(name: "streamlink", arguments: arguments(for: "streamlink"), maximumStdoutBytes: 64 * 1_024,
                                                   monitorOutputDirectory: parent, maximumOutputBytes: BundledMediaRuntime.maximumMediaBytes)
            }
            if helperOutput.truncated {
                Self.logger.info("Download helper output truncated after \(helperOutput.byteCount, privacy: .public) bytes; completed files remain authoritative.")
            }
            try Task.checkCancellation()
            let produced = try outputFiles(in: parent, maximumCount: 8)
            if operation == .downloadRemoteSubtitles {
                let subtitleFiles = produced.filter { ["vtt", "srt"].contains($0.pathExtension.lowercased()) }
                guard !subtitleFiles.isEmpty else { throw KioFailure.verification("Reel finished without a subtitle file.") }
                let sourceTitle = (try? ReelInspectionStore.readInfo(from: input).title)
                    ?? ReelMediaRouter.safeTitle(url.deletingPathExtension().lastPathComponent)
                var artifacts: [ArtifactRef] = []
                do {
                    for (index, file) in subtitleFiles.enumerated() {
                        try Task.checkCancellation()
                        let output = try OutputLocation.makeURL(for: [input], baseName: "\(sourceTitle)-Subtitles-\(index + 1)", fileExtension: file.pathExtension.lowercased())
                        try FileManager.default.moveItem(at: file, to: output)
                        artifacts.append(try ArtifactRef.inspect(output, parentID: input.id)
                            .withVerificationNote("Downloaded subtitle track \(index + 1) from \(subtitleFiles.count)."))
                    }
                    ReelInspectionStore.removeInfoIfInternal(input)
                    return artifacts
                } catch {
                    for artifact in artifacts { try? FileManager.default.removeItem(at: artifact.fileURL) }
                    throw error
                }
            }
            guard let first = produced.first else { throw KioFailure.verification("Reel finished without a usable output file.") }
            let sourceTitle = (try? ReelInspectionStore.readInfo(from: input).title)
                ?? ReelMediaRouter.safeTitle(url.deletingPathExtension().lastPathComponent)
            let normalized = try await normalizeDownloadedMedia(first, operation: operation, requestedFormat: format,
                                                                quality: quality, workspace: parent)
            let output = try OutputLocation.makeURL(for: [input], baseName: sourceTitle, fileExtension: normalized.fileExtension)
            try FileManager.default.moveItem(at: normalized.url, to: output)
            let artifact = try ArtifactRef.inspect(output, parentID: input.id).withVerificationNote(normalized.note)
            ReelInspectionStore.removeInfoIfInternal(input)
            return [artifact]
        }
    }

    private static func outputFiles(in root: URL, maximumCount: Int) throws -> [URL] {
        try ReelOutputPolicy.scan(root: root, maximumCount: maximumCount, maximumBytes: 8 * 1_024 * 1_024 * 1_024)
    }

    private static func downloadDirect(_ url: URL, input: ArtifactRef, operation: ToolOperation,
                                       requestedFormat: String?, quality: String?) async throws -> ArtifactRef {
        let (downloaded, http) = try await BoundedReelDownloader.download(url, maximumBytes: 8 * 1_024 * 1_024 * 1_024)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard (200..<300).contains(http.statusCode), let finalURL = http.url,
              (try? ReelMediaRouter.safeURL(finalURL)) != nil else {
            throw KioFailure.processing("The direct media URL didn't return a safe public media response.")
        }
        let size = (try? downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= 8 * 1_024 * 1_024 * 1_024 else { throw KioFailure.verification("The direct media download was empty or exceeded the 8 GB limit.") }
        let sourceExtension = url.pathExtension.lowercased()
        let ext = requestedFormat ?? (sourceExtension == "m4v" ? "mp4" : sourceExtension)
        guard ["mp4", "m4v", "mov", "webm", "mkv", "mp3", "m4a", "wav", "flac", "jpg", "jpeg", "png", "webp", "heic"].contains(ext) else {
            throw KioFailure.unsupported("Reel couldn't determine a safe file extension for this direct media URL.")
        }
        let title = (try? ReelInspectionStore.readInfo(from: input).title)
            ?? ReelMediaRouter.safeTitle(url.deletingPathExtension().lastPathComponent)
        let output = try OutputLocation.makeURL(for: [input], baseName: title, fileExtension: ext)
        let staging = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: downloaded, to: staging)
        let stagedSize = (try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard stagedSize == size, stagedSize > 0, stagedSize <= 8 * 1_024 * 1_024 * 1_024 else {
            throw KioFailure.verification("The direct media copy did not pass its size check.")
        }
        let normalized = try await normalizeDownloadedMedia(staging, operation: operation, requestedFormat: requestedFormat,
                                                            quality: quality, workspace: staging.deletingLastPathComponent())
        guard normalized.fileExtension == ext || (ext == "m4v" && normalized.fileExtension == "mp4") else {
            throw KioFailure.verification("The direct response did not match the selected media format.")
        }
        if normalized.url != staging {
            try FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: normalized.url, to: staging)
        }
        try OutputLocation.commit(staging, to: output)
        return try ArtifactRef.inspect(output, parentID: input.id).withVerificationNote(normalized.note)
    }

    private static func normalizeDownloadedMedia(_ source: URL, operation: ToolOperation, requestedFormat: String?,
                                                 quality: String?, workspace: URL) async throws -> (url: URL, fileExtension: String, note: String?) {
        guard [.downloadRemoteAudio, .downloadRemoteVideo, .downloadRemoteLive].contains(operation) else {
            return (source, source.pathExtension.lowercased(), nil)
        }
        let probe = try await BundledMediaRuntime.probe(source)
        let duration = probe.duration
        guard let duration, duration.isFinite, duration > 0 else {
            throw KioFailure.verification("Reel couldn't verify a finite media duration.")
        }
        let intermediate = workspace.appendingPathComponent("Kio-Reel-normalized-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: intermediate) }

        if operation == .downloadRemoteAudio {
            guard probe.hasAudio else { throw KioFailure.verification("The downloaded source does not contain an audio stream.") }
            guard let target = AudioTargetFormat(rawValue: requestedFormat ?? source.pathExtension.lowercased()) else {
                throw KioFailure.invalidInput("Choose MP3, M4A, WAV, or FLAC for audio output.")
            }
            let matches = probe.isCompatibleAudio(with: target)
            var final = source
            if !matches || source.pathExtension.lowercased() != target.rawValue {
                try await BundledMediaRuntime.transcodeAudio(source, to: intermediate, format: target)
                final = intermediate
            }
            let verified = try await BundledMediaRuntime.probe(final)
            let size = Int64((try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard verified.isCompatibleAudio(with: target), verified.duration.map({ $0.isFinite && abs($0 - duration) <= max(1, duration * 0.02) }) == true,
                  size > 0, size <= BundledMediaRuntime.maximumMediaBytes,
                  final.pathExtension.lowercased() == target.rawValue else {
                throw KioFailure.verification("Reel's audio output failed its format, stream, duration, or size checks.")
            }
            return (final, target.rawValue, "Verified \(target.rawValue.uppercased()) audio-only media. Original source remains unchanged.")
        }

        guard probe.hasVideo,
              let video = probe.streams.first(where: { $0.codec_type == "video" }),
              let height = video.height, height > 0, let width = video.width, width > 0 else {
            throw KioFailure.verification("The downloaded source does not contain a readable video stream.")
        }
        let rawFormat = requestedFormat ?? source.pathExtension.lowercased()
        let normalizedFormat = rawFormat == "m4v" ? "mp4" : rawFormat
        guard let target = ReelVideoContainer(rawValue: normalizedFormat) else {
            throw KioFailure.invalidInput("Choose MP4, WebM, MKV, or MOV for the video output.")
        }
        let requestedHeight = quality.flatMap { $0 == "best" ? nil : Int($0.dropLast()) }
        if let requestedHeight, ![360, 480, 720, 1080, 1440, 2160].contains(requestedHeight) {
            throw KioFailure.invalidInput("Reel received an unsupported video quality selection.")
        }
        let needsResize = requestedHeight.map { height > $0 } ?? false
        var final = source
        if !probe.isCompatible(with: target) || needsResize {
            try await BundledMediaRuntime.transcodeVideo(source, to: intermediate, container: target, maximumHeight: requestedHeight)
            final = intermediate
        }
        let verified = try await BundledMediaRuntime.probe(final)
        let resultVideo = verified.streams.first(where: { $0.codec_type == "video" })
        let resultSize = Int64((try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let heightWithinChoice = requestedHeight.map { (resultVideo?.height ?? Int.max) <= $0 } ?? true
        guard verified.hasVideo, (!probe.hasAudio || verified.hasAudio), verified.isCompatible(with: target),
              resultVideo?.width.map({ $0 > 0 }) == true, resultVideo?.height.map({ $0 > 0 }) == true,
              verified.duration.map({ $0.isFinite && abs($0 - duration) <= max(1, duration * 0.02) }) == true,
              heightWithinChoice, resultSize > 0, resultSize <= BundledMediaRuntime.maximumMediaBytes else {
            throw KioFailure.verification("Reel's video output failed its container, codec, stream, duration, resolution, or size checks.")
        }
        let actualHeight = resultVideo?.height ?? height
        let note: String
        if let requestedHeight, actualHeight < requestedHeight {
            note = "Verified \(normalizedFormat.uppercased()) video at \(actualHeight)p; this source has no variant at the selected \(requestedHeight)p."
        } else {
            note = "Verified \(normalizedFormat.uppercased()) video at \(actualHeight)p with compatible streams."
        }
        return (final, normalizedFormat, note)
    }

    private static let logger = Logger(subsystem: "app.kio.mac", category: "Reel")

    private static func runHelper(name: String, arguments: [String], maximumStdoutBytes: Int,
                                  monitorOutputDirectory: URL? = nil,
                                  maximumOutputBytes: Int64 = BundledMediaRuntime.maximumMediaBytes,
                                  maximumDurationSeconds: TimeInterval = 4 * 60 * 60) async throws -> ReelBoundedProcessOutput {
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
        var limitFailure: KioFailure?
        var lastSizeCheck = Date.distantPast
        let startedAt = Date()
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if Date().timeIntervalSince(startedAt) > maximumDurationSeconds {
                    limitFailure = .verification("Reel stopped the helper after its four-hour task limit.")
                    process.terminate()
                    break
                }
                if let monitorOutputDirectory, Date().timeIntervalSince(lastSizeCheck) >= 0.5 {
                    lastSizeCheck = Date()
                    do { _ = try ReelOutputPolicy.currentSize(root: monitorOutputDirectory, maximumBytes: maximumOutputBytes) }
                    catch let failure as KioFailure {
                        limitFailure = failure
                        process.terminate()
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(120))
            }
        } catch is CancellationError {
            if process.isRunning { process.terminate() }
            try? await Task.sleep(for: .milliseconds(250))
            if process.isRunning { process.interrupt() }
            _ = await outputTask.value
            _ = await errorTask.value
            throw CancellationError()
        } catch {
            if process.isRunning { process.terminate() }
            try? await Task.sleep(for: .milliseconds(250))
            if process.isRunning { process.interrupt() }
            _ = await outputTask.value
            _ = await errorTask.value
            throw error
        }
        let errorOutput = await errorTask.value
        let output = await outputTask.value
        logger.info("Helper \(name, privacy: .public) exited with status \(process.terminationStatus, privacy: .public); stdout bytes=\(output.byteCount, privacy: .public), truncated=\(output.truncated, privacy: .public), stderr bytes=\(errorOutput.byteCount, privacy: .public), stderr truncated=\(errorOutput.truncated, privacy: .public).")
        let detail = String(data: errorOutput.data, encoding: .utf8) ?? ""
        if let limitFailure { throw limitFailure }
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
        ReelInspectionStore.prune()
        let name = ReelMediaRouter.safeTitle(info.title) + "-inspection"
        let url = try OutputLocation.makeURL(in: ReelInspectionStore.directory, baseName: name, fileExtension: "kio-reel-info")
        try JSONEncoder().encode(info).write(to: url, options: .atomic)
        return try ArtifactRef.inspect(url, parentID: input.id)
    }
}
