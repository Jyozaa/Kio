import Foundation
import Testing
import KioCore
@testable import KioTools

@Test func reelRoutesSupportedSourcesAndRejectsUnsafeURLSchemesAndPrivateHosts() throws {
    #expect(ReelMediaRouter.backend(for: URL(string: "https://cdn.example/movie.mp4")!) == .directHTTP)
    #expect(ReelMediaRouter.backend(for: URL(string: "https://cdn.example/audio.flac")!) == .directHTTP)
    #expect(ReelMediaRouter.backend(for: URL(string: "https://media.example/live.m3u8" )!, availableHelpers: []) == .ytDlp)
    #expect(ReelMediaRouter.backend(for: URL(string: "https://media.example/live.m3u8")!, availableHelpers: ["streamlink"]) == .streamlink)
    #expect(ReelMediaRouter.backend(for: URL(string: "https://imgur.com/gallery/set")!, availableHelpers: []) == .ytDlp)
    #expect(ReelMediaRouter.backend(for: URL(string: "https://imgur.com/gallery/set")!, availableHelpers: ["gallery-dl"]) == .galleryDL)

    for raw in ["file:///etc/passwd", "ftp://media.example/video.mp4", "http://127.0.0.1/secret", "http://[::1]/secret", "http://localhost/private"] {
        do {
            _ = try ReelMediaRouter.safeURL(URL(string: raw)!)
            Issue.record("Reel must reject unsafe URL: \(raw)")
        } catch { #expect(error.localizedDescription.contains("URL")) }
    }
}

@Test func reelInspectionDecoderSanitizesMetadataAndRejectsMalformedOrOversizedOutput() throws {
    let remoteURL = URL(string: "https://media.example/watch")!
    let fixture = Data(#"{"title":"../unsafe: title?","duration":92.5,"extractor_key":"Example","is_live":false,"audio_ext":"m4a","formats":[{"height":720,"ext":"mp4","acodec":"none"},{"height":1080,"ext":"webm","acodec":"opus"},{"height":480,"ext":"mkv","acodec":"none"}]}"#.utf8)
    let info = try ReelInspectionDecoder.decode(fixture, remoteURL: remoteURL)
    #expect(info.remoteURL == remoteURL.absoluteString)
    #expect(info.title == "unsafe- title")
    #expect(info.durationSeconds == 92.5)
    #expect(info.source == "Example")
    #expect(!info.isLive)
    #expect(info.qualities == ["best", "1080p", "720p", "480p"])
    #expect(info.videoFormats == ["mkv", "mp4", "webm"])
    #expect(info.audioAvailable)

    do {
        _ = try ReelInspectionDecoder.decode(Data("[]".utf8), remoteURL: remoteURL)
        Issue.record("Malformed inspection output must be rejected.")
    } catch { #expect(error.localizedDescription.contains("malformed")) }
    do {
        _ = try ReelInspectionDecoder.decode(Data(repeating: 0x20, count: 8_000_001), remoteURL: remoteURL)
        Issue.record("Inspection output over 8 MB must be rejected before parsing.")
    } catch { #expect(error.localizedDescription.contains("malformed")) }
}

@Test func reelHelperTrustFailureClassificationAndPreparedBinaryChecksAreBounded() throws {
    #expect(ReelHelperFailureKind.classify("ERROR: DRM protected / Widevine") == .drmProtected)
    #expect(ReelHelperFailureKind.classify("Please sign in to continue") == .authenticationRequired)
    #expect(ReelHelperFailureKind.classify("network timeout") == .processFailure)
    #expect(ReelHelperManager.matchesSHA256(Data("abc".utf8), expected: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
    #expect(!ReelHelperManager.matchesSHA256(Data("abc".utf8), expected: String(repeating: "0", count: 64)))
    #expect(!ReelHelperManager.matchesSHA256(Data("abc".utf8), expected: "not-a-checksum"))

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioReelHelpers-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(!ReelMediaRouter.isPreparedBinary("yt-dlp", in: folder))
    #expect(!ReelMediaRouter.isPreparedBinary("arbitrary-command", in: folder))
    let helper = folder.appendingPathComponent("yt-dlp")
    try Data("fixture only".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    #expect(ReelMediaRouter.isPreparedBinary("yt-dlp", in: folder))
}

@Test func reelManifestPinsBundledRuntimeVersionsPathsAndLicenses() throws {
    let manifest = try #require(ReelRuntimeManifest.bundled)
    #expect(manifest.architecture == "arm64-apple-darwin")
    #expect(manifest.component("yt-dlp")?.version == "2026.08.19")
    #expect(manifest.component("deno")?.version == "2.9.7")
    #expect(manifest.component("ffmpeg")?.license.contains("LGPL") == true)
    #expect(manifest.component("lame")?.license == "LGPL-2.0-or-later")
    #expect(manifest.component("streamlink")?.version == "8.6.0")
    #expect(manifest.component("gallery-dl") == nil)
    #expect(manifest.wheels.count == 20)
    #expect(manifest.wheels.allSatisfy { $0.sha256.count == 64 && $0.url.host == "files.pythonhosted.org" })

    let root = URL(fileURLWithPath: "/tmp/Kio.app/Contents/Resources/Reel")
    #expect(ReelRuntime.url(for: "deno", in: root, manifest: manifest)?.path == root.appendingPathComponent("deno").path)
    #expect(ReelRuntime.url(for: "python", in: root, manifest: manifest)?.path == root.appendingPathComponent("streamlink/python/bin/python3.12").path)
    #expect(ReelRuntime.url(for: "ffprobe", in: root, manifest: manifest)?.path == root.appendingPathComponent("ffmpeg/bin/ffprobe").path)
}

@Test func reelOutputPolicyContainsFilesAndEnforcesCountAndByteCaps() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("KioReelOutput-\(UUID().uuidString)", isDirectory: true)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("KioReelOutside-\(UUID().uuidString).mp4")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    try Data(repeating: 1, count: 4).write(to: root.appendingPathComponent("a.mp4"))
    try Data(repeating: 2, count: 5).write(to: root.appendingPathComponent("b.mp4"))
    try Data(repeating: 3, count: 10).write(to: outside)
    try Data("hidden".utf8).write(to: root.appendingPathComponent(".secret"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.mp4"), withDestinationURL: outside)

    let outputs = try ReelOutputPolicy.scan(root: root, maximumCount: 2, maximumBytes: 9)
    #expect(outputs.map(\.lastPathComponent) == ["a.mp4", "b.mp4"])
    do {
        _ = try ReelOutputPolicy.scan(root: root, maximumCount: 1, maximumBytes: 100)
        Issue.record("Reel must refuse output sets over its count limit.")
    } catch { #expect(error.localizedDescription.contains("more than 1 outputs")) }
    do {
        _ = try ReelOutputPolicy.scan(root: root, maximumCount: 5, maximumBytes: 8)
        Issue.record("Reel must refuse output sets over its byte limit.")
    } catch { #expect(error.localizedDescription.contains("size limit")) }
}

@Test func reelTemporaryWorkspaceCleansUpAfterSuccessAndCancellation() async throws {
    let successURL = FileManager.default.temporaryDirectory.appendingPathComponent("KioReelTempSuccess-\(UUID().uuidString)", isDirectory: true)
    let cancelURL = FileManager.default.temporaryDirectory.appendingPathComponent("KioReelTempCancel-\(UUID().uuidString)", isDirectory: true)
    let value = try await ReelTemporaryWorkspace.withDirectory(at: successURL) { directory -> String in
        try Data("fixture".utf8).write(to: directory.appendingPathComponent("partial.bin"))
        return "complete"
    }
    #expect(value == "complete")
    #expect(!FileManager.default.fileExists(atPath: successURL.path))

    do {
        try await ReelTemporaryWorkspace.withDirectory(at: cancelURL) { directory -> Void in
            try Data("partial".utf8).write(to: directory.appendingPathComponent("partial.bin"))
            throw CancellationError()
        }
        Issue.record("Cancellation should propagate from the helper workspace.")
    } catch is CancellationError { }
    #expect(!FileManager.default.fileExists(atPath: cancelURL.path))
}
