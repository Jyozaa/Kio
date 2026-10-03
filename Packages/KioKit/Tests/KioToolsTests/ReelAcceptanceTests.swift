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
    #expect(ReelMediaRouter.backend(for: URL(string: "https://imgur.com/gallery/set")!, availableHelpers: ["gallery-dl"]) == .ytDlp)

    for raw in ["file:///etc/passwd", "ftp://media.example/video.mp4", "http://127.0.0.1/secret", "http://[::1]/secret", "http://localhost/private"] {
        do {
            _ = try ReelMediaRouter.safeURL(URL(string: raw)!)
            Issue.record("Reel must reject unsafe URL: \(raw)")
        } catch { #expect(error.localizedDescription.contains("URL")) }
    }
}

@Test func reelInspectionDecoderSanitizesCompactMetadataAndNormalizesDuplicateFormats() throws {
    let remoteURL = URL(string: "https://media.example/watch")!
    let fixture = Data((#"{"title":"../unsafe: title?","duration":92.5,"extractor_key":"Example","is_live":false,"audio_ext":"m4a","formats":[{"format_id":"v2160","height":2160,"ext":"mp4","acodec":"none","vcodec":"avc1"},{"format_id":"v2160","height":2160,"ext":"mp4","acodec":"none","vcodec":"avc1"},{"format_id":"v1440","height":1440,"ext":"webm","acodec":"none","vcodec":"vp9"},{"format_id":"v1080","height":1080,"ext":"webm","acodec":"opus","vcodec":"vp9"},{"format_id":"v720","height":720,"ext":"mp4","acodec":"aac","vcodec":"h264"},{"format_id":"v480","height":480,"ext":"mkv","acodec":"none","vcodec":"h264"},{"format_id":"v360","height":360,"ext":"mp4","acodec":"none","vcodec":"h264"},{"format_id":"a140","ext":"m4a","acodec":"aac","vcodec":"none"},{"format_id":"a251","ext":"webm","acodec":"opus","vcodec":"none"}]}"# + "\n").utf8)
    let info = try ReelInspectionDecoder.decode(fixture, remoteURL: remoteURL)
    #expect(info.remoteURL == remoteURL.absoluteString)
    #expect(info.title == "unsafe- title")
    #expect(info.durationSeconds == 92.5)
    #expect(info.source == "Example")
    #expect(info.isLive == false)
    #expect(info.qualities == ["best", "2160p", "1440p", "1080p", "720p", "480p", "360p"])
    #expect(info.videoFormats == ["mkv", "mov", "mp4", "webm"])
    #expect(info.audioAvailable == true)

    #expect(try ReelInspectionDecoder.decode(Data("  \n{\"formats\":[{\"acodec\":\"none\"}]}\n  ".utf8), remoteURL: remoteURL).audioAvailable == false)
    #expect(try ReelInspectionDecoder.decode(Data("{\"audio_ext\":\"none\"}".utf8), remoteURL: remoteURL).audioAvailable == false)
    #expect(try ReelInspectionDecoder.decode(Data("{\"formats\":[{\"acodec\":\"aac\"}]}".utf8), remoteURL: remoteURL).audioAvailable == true)
    #expect(try ReelInspectionDecoder.decode(Data("{\"audio_ext\":\"m4a\"}".utf8), remoteURL: remoteURL).audioAvailable == true)

    let legacyInspection = Data(#"{"remoteURL":"https://media.example/watch","title":"Legacy","source":"Example","isLive":false,"qualities":["best"],"videoFormats":["mp4"],"audioAvailable":false}"#.utf8)
    let legacyInfo = try JSONDecoder().decode(ReelInspectionInfo.self, from: legacyInspection)
    #expect(legacyInfo.variants.isEmpty)
    #expect(legacyInfo.audioAvailable == false)
    #expect(legacyInfo.isLive == false)

    let hundreds = (0..<700).map { _ in ["height": 720, "ext": "mp4", "acodec": "aac", "vcodec": "avc1"] as [String: Any] }
    let manyFormats = try JSONSerialization.data(withJSONObject: ["formats": hundreds])
    let boundedInfo = try ReelInspectionDecoder.decode(manyFormats, remoteURL: remoteURL)
    #expect(boundedInfo.qualities == ["best", "720p"])

    for (data, message) in [
        (Data("".utf8), "didn't receive"),
        (Data("[]".utf8), "couldn't decode"),
        (Data("<html>not media</html>".utf8), "couldn't decode"),
        (Data(repeating: 0x20, count: ReelInspectionDecoder.maximumOutputBytes + 1), "too much media metadata")
    ] {
        do {
            _ = try ReelInspectionDecoder.decode(data, remoteURL: remoteURL)
            Issue.record("Invalid inspection output must be rejected: \(message)")
        } catch { #expect(error.localizedDescription.contains(message)) }
    }
}

@Test func reelBestQualityPickerOffersContainersAcrossConcreteVariantHeights() throws {
    let remoteURL = URL(string: "https://media.example/watch")!
    let fixture = Data(#"{"formats":[{"format_id":"2160-webm","height":2160,"ext":"webm","vcodec":"vp9","acodec":"none"},{"format_id":"1080-mp4","height":1080,"ext":"mp4","vcodec":"h264","acodec":"aac"}]}"#.utf8)
    let info = try ReelInspectionDecoder.decode(fixture, remoteURL: remoteURL)

    #expect(info.availableQualities == ["best", "2160p", "1080p"])
    #expect(info.availableVideoFormats(for: "best") == ["mp4", "webm"])
    #expect(info.availableVideoFormats(for: "2160p") == ["webm"])
    #expect(info.availableVideoFormats(for: "1080p") == ["mp4"])
}

@Test func streamlinkInspectionIsProviderNeutralAndItsSelectedQualityIsPreserved() throws {
    let url = URL(string: "https://media.example/watch/123")!
    let fixture = Data(#"{"plugin":"plugins.generic","metadata":{"title":"A live title"},"streams":{"best":{"type":"HLSStream"},"720p":{"type":"HLSStream"},"720p_alt":{"type":"HLSStream"},"480p":{"type":"HLSStream"}}}"#.utf8)
    let info = try ReelStreamlinkInspectionDecoder.decode(fixture, remoteURL: url)
    #expect(info.title == "A live title")
    #expect(info.source == "generic")
    #expect(info.qualities == ["best", "720p", "480p"])
    #expect(info.videoFormats == ["mp4"])
    #expect(info.audioAvailable == nil)
    #expect(info.isLive == nil)
    #expect(info.variants.allSatisfy { $0.needsTranscode })
    #expect(info.variants.allSatisfy { $0.container == "mp4" && $0.sourceContainer == nil })
    #expect(info.variants.allSatisfy { $0.formatNote?.contains("source container unknown") == true })
    let confirmedLive = try ReelStreamlinkInspectionDecoder.decode(
        Data(#"{"is_live":true,"streams":{"720p":{"type":"HLSStream"}}}"#.utf8), remoteURL: url)
    #expect(confirmedLive.isLive == true)
    #expect(confirmedLive.audioAvailable == nil)

    let inspect = try ReelCommandBuilder.streamlinkInspection(url: url)
    #expect(inspect.contains("--json"))
    #expect(inspect.contains("--no-config"))
    #expect(inspect.contains("--no-plugin-sideloading"))
    #expect(inspect.last == url.absoluteString)
    let download = try ReelCommandBuilder.streamlink(url: url, outputPath: "/tmp/kio-selected.ts", quality: "720p")
    #expect(download.last == "720p")
    #expect(!download.contains("best"))
}

@Test func reelVariantsChooseExactH264AACIDsAndExposeQualityFormatDependencies() throws {
    let url = URL(string: "https://media.example/watch")!
    let fixture = Data(#"{"title":"Variant fixture","formats":[{"format_id":"137","width":1920,"height":1080,"fps":30,"tbr":3200,"filesize":4000000,"protocol":"https","ext":"mp4","vcodec":"avc1.640028","acodec":"none"},{"format_id":"399","width":1920,"height":1080,"ext":"webm","vcodec":"av01.0.08M.08","acodec":"none"},{"format_id":"399-2160","width":3840,"height":2160,"ext":"webm","vcodec":"av01.0.08M.08","acodec":"none"},{"format_id":"22","width":1280,"height":720,"ext":"mp4","vcodec":"avc1.4d401f","acodec":"mp4a.40.2"},{"format_id":"140","ext":"m4a","abr":128,"filesize_approx":1000000,"language":"en","protocol":"https","vcodec":"none","acodec":"mp4a.40.2"},{"format_id":"251","ext":"webm","vcodec":"none","acodec":"opus"}]}"#.utf8)
    let info = try ReelInspectionDecoder.decode(fixture, remoteURL: url)
    let h264AAC = try #require(info.variants.first { $0.quality == "1080p" && $0.container == "mp4" })
    #expect(h264AAC.width == 1920)
    #expect(h264AAC.height == 1080)
    #expect(h264AAC.fps == 30)
    #expect(h264AAC.bitrate == 3328)
    #expect(h264AAC.filesize == 5_000_000)
    #expect(h264AAC.hasVideo == true)
    #expect(h264AAC.hasAudio == true)
    #expect(h264AAC.sourceContainer == "mp4")
    #expect(h264AAC.sourceProtocol == "https")
    #expect(h264AAC.language == "en")
    #expect(h264AAC.sourceBackend == "yt-dlp")
    let mp4 = try #require(ReelVariantSelector.select(info.variants, quality: "1080p", container: "mp4"))
    #expect(mp4.videoFormatID == "137")
    #expect(mp4.audioFormatID == "140")
    #expect(!mp4.needsTranscode)
    #expect(ReelVariantSelector.select(info.variants, quality: "2160p", container: "webm")?.needsTranscode == false)
    #expect(ReelVariantSelector.select(info.variants, quality: "720p", container: "webm") == nil)

    let command = try ReelCommandBuilder.ytDlp(operation: .downloadRemoteVideo, url: url,
        outputTemplate: "/tmp/reel.%(ext)s", quality: "1080p", format: "mp4",
        ffmpegDirectory: URL(fileURLWithPath: "/app/Reel/ffmpeg"), variant: mp4)
    let formatIndex = try #require(command.firstIndex(of: "-f"))
    #expect(command[formatIndex + 1] == "137+140")
    #expect(command.contains("--merge-output-format"))
    #expect(command[try #require(command.firstIndex(of: "--merge-output-format")) + 1] == "mp4")

    let fallback = ReelVariantSelector.select(
        ReelVariantSelector.build(from: [
            ["format_id": "399", "height": 1080, "ext": "webm", "vcodec": "av01", "acodec": "none"],
            ["format_id": "251", "ext": "webm", "vcodec": "none", "acodec": "opus"]
        ]), quality: "1080p", container: "mp4")
    #expect(fallback?.formatSelector == "399+251")
    #expect(fallback?.needsTranscode == true)
    let fallbackCommand = try ReelCommandBuilder.ytDlp(operation: .downloadRemoteVideo, url: url,
        outputTemplate: "/tmp/reel.%(ext)s", quality: "1080p", format: "mp4",
        ffmpegDirectory: URL(fileURLWithPath: "/app/Reel/ffmpeg"), variant: fallback)
    #expect(fallbackCommand[try #require(fallbackCommand.firstIndex(of: "--merge-output-format")) + 1] == "mkv")

    let exactNeedsConversion = ReelVariantSelector.build(from: [
        ["format_id": "399", "height": 1080, "ext": "webm", "vcodec": "av01.0.08M.08", "acodec": "none"],
        ["format_id": "22", "height": 720, "ext": "mp4", "vcodec": "avc1.4d401f", "acodec": "mp4a.40.2"]
    ])
    let selectedExact = try #require(ReelVariantSelector.resolve(exactNeedsConversion, quality: "1080p", container: "mp4"))
    #expect(selectedExact.variant.quality == "1080p")
    #expect(selectedExact.variant.videoFormatID == "399")
    #expect(selectedExact.variant.needsTranscode)
    #expect(!selectedExact.usedLowerQualityFallback)
    #expect(selectedExact.method == .transcode)
    #expect(selectedExact.diagnosticDescription.contains("video=399"))
    #expect(selectedExact.diagnosticDescription.contains("method=transcode"))
    let bestMP4 = try #require(ReelVariantSelector.select(exactNeedsConversion, quality: "best", container: "mp4"))
    #expect(bestMP4.quality == "720p")
    #expect(bestMP4.needsTranscode == false)

    let noExactQuality = ReelVariantSelector.build(from: [
        ["format_id": "22", "height": 720, "ext": "mp4", "vcodec": "avc1.4d401f", "acodec": "mp4a.40.2"]
    ])
    let selectedLower = try #require(ReelVariantSelector.resolve(noExactQuality, quality: "1080p", container: "mp4"))
    #expect(selectedLower.variant.quality == "720p")
    #expect(!selectedLower.variant.needsTranscode)
    #expect(selectedLower.usedLowerQualityFallback)
    #expect(selectedLower.diagnosticDescription.contains("fallback=lower-quality"))
}

@Test func reelBestQualityIsResolvedPerContainerAndExactSourceCanConvert() throws {
    let fixture: [[String: Any]] = [
        ["format_id": "2160-av1", "width": 3840, "height": 2160, "ext": "webm", "vcodec": "av01.0.08M.08", "acodec": "opus", "tbr": 9_000],
        ["format_id": "1080-h264", "width": 1920, "height": 1080, "ext": "mp4", "vcodec": "avc1.640028", "acodec": "mp4a.40.2", "fps": 30, "vbr": 4_000],
        ["format_id": "1080-vp9", "width": 1920, "height": 1080, "ext": "webm", "vcodec": "vp09.00.40.08", "acodec": "opus", "fps": 60, "vbr": 3_500],
        ["format_id": "720-h264", "width": 1280, "height": 720, "ext": "mp4", "vcodec": "avc1.4d401f", "acodec": "mp4a.40.2", "fps": 30, "vbr": 2_000]
    ]
    let variants = ReelVariantSelector.build(from: fixture)
    let bestMP4 = try #require(ReelVariantSelector.resolve(variants, quality: "best", container: "mp4"))
    let bestWebM = try #require(ReelVariantSelector.resolve(variants, quality: "best", container: "webm"))
    #expect(bestMP4.variant.quality == "1080p")
    #expect(bestMP4.variant.videoFormatID == "1080-h264")
    #expect(bestWebM.variant.quality == "2160p")
    #expect(bestWebM.variant.videoFormatID == "2160-av1")

    let exact1080 = try #require(ReelVariantSelector.select(variants, quality: "1080p", container: "mp4"))
    #expect(exact1080.videoFormatID == "1080-h264")
    #expect(!exact1080.needsTranscode)
    let exact2160 = try #require(ReelVariantSelector.resolve(variants, quality: "2160p", container: "mp4"))
    #expect(exact2160.variant.quality == "2160p")
    #expect(exact2160.variant.videoFormatID == "2160-av1")
    #expect(exact2160.variant.needsTranscode)
    #expect(!exact2160.usedLowerQualityFallback)
}

@Test func reelAudioLanguagePreferenceOutranksExtractorOrderingAndCodecConvenience() throws {
    let video: [String: Any] = ["format_id": "137", "height": 1080, "width": 1920,
        "ext": "mp4", "vcodec": "avc1.640028", "acodec": "none", "vbr": 4_000]
    let dubbed: [String: Any] = ["format_id": "audio-dub", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2",
        "language": "en", "language_preference": -1, "format_note": "dubbed", "abr": 128]
    let originalAAC: [String: Any] = ["format_id": "audio-original-aac", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2",
        "language": "ja", "language_preference": 10, "format_note": "original", "audio_channels": 2,
        "abr": 96, "preference": 2, "source_preference": 1]
    let defaultAAC: [String: Any] = ["format_id": "audio-default", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2",
        "language": "en", "language_preference": 5, "format_note": "default", "abr": 192]
    let originalOpus: [String: Any] = ["format_id": "audio-original-opus", "ext": "webm", "vcodec": "none", "acodec": "opus",
        "language": "ja", "language_preference": 10, "format_note": "original", "audio_channels": 2,
        "abr": 160, "preference": 1]

    for formats in [[video, dubbed, originalAAC, defaultAAC, originalOpus],
                    [originalOpus, defaultAAC, originalAAC, dubbed, video]] {
        let variants = ReelVariantSelector.build(from: formats)
        let selected = try #require(ReelVariantSelector.resolve(variants, quality: "1080p", container: "mp4"))
        #expect(selected.variant.videoFormatID == "137")
        #expect(selected.variant.audioFormatID == "audio-original-aac")
        #expect(selected.variant.language == "ja")
        #expect(selected.variant.languagePreference == 10)
        #expect(selected.variant.formatNote == "original")
        #expect(selected.variant.audioChannels == 2)
        #expect(selected.variant.abr == 96)
        #expect(selected.variant.preference == 2)
        #expect(selected.variant.sourcePreference == 1)
        #expect(!selected.variant.needsTranscode)
    }

    let progressiveDub: [String: Any] = ["format_id": "progressive-dub", "height": 1080, "width": 1920,
        "ext": "mp4", "vcodec": "avc1.640028", "acodec": "mp4a.40.2", "language": "en",
        "language_preference": -1, "format_note": "dubbed", "vbr": 4_000]
    let progressiveVariants = ReelVariantSelector.build(from: [progressiveDub, dubbed, originalAAC, defaultAAC, originalOpus])
    let progressiveSelection = try #require(ReelVariantSelector.resolve(progressiveVariants, quality: "1080p", container: "mp4"))
    #expect(progressiveSelection.variant.audioFormatID == "audio-original-aac")
    #expect(progressiveSelection.variant.language == "ja")

    let originalRequiresConversion = ReelVariantSelector.build(from: [progressiveDub, originalOpus])
    let bestOriginal = try #require(ReelVariantSelector.resolve(originalRequiresConversion, quality: "best", container: "mp4"))
    #expect(bestOriginal.variant.audioFormatID == "audio-original-opus")
    #expect(bestOriginal.variant.needsTranscode)
    #expect(bestOriginal.variant.languagePreference == 10)

    let preferenceOnly = ReelVariantSelector.build(from: [video,
        ["format_id": "default", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "language": "en", "language_preference": 5],
        ["format_id": "original", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "language": "ja", "language_preference": 10]])
    let preferenceSelection = try #require(ReelVariantSelector.resolve(preferenceOnly, quality: "1080p", container: "mp4"))
    #expect(preferenceSelection.variant.audioFormatID == "original")
}

@Test func reelInspectionPolicyAppliesOnePersistedSizeAndVariantBound() throws {
    let url = URL(string: "https://media.example/watch")!
    let formats: [[String: Any]] = (0..<ReelInspectionPolicy.maximumFormats).map { index in
        ["format_id": "v\(index)", "height": 1080, "width": 1920, "ext": "mp4",
         "vcodec": "avc1.640028", "acodec": "mp4a.40.2", "format_note": String(repeating: "x", count: 160)]
    }
    let source = try JSONSerialization.data(withJSONObject: ["formats": formats])
    #expect(source.count <= ReelInspectionPolicy.maximumJSONBytes)
    let decoded = try ReelInspectionDecoder.decode(source, remoteURL: url)
    let persisted = try JSONEncoder().encode(decoded)
    #expect(persisted.count <= ReelInspectionPolicy.maximumJSONBytes)
    #expect(try ReelInspectionPolicy.decodePersistedInfo(persisted) == decoded)

    let atLimit = ReelInspectionInfo(remoteURL: url.absoluteString, title: "Bounded", durationSeconds: nil,
        source: "Fixture", isLive: false, qualities: ["best"], videoFormats: ["mp4"], audioAvailable: true,
        variants: (0..<ReelInspectionPolicy.maximumVariants).map { index in
            ReelVariant(quality: "1080p", container: "mp4", videoFormatID: "v\(index)", needsTranscode: false)
        })
    var tooManyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(atLimit)) as? [String: Any])
    var rawVariants = try #require(tooManyObject["variants"] as? [[String: Any]])
    rawVariants.append(try #require(rawVariants.first))
    tooManyObject["variants"] = rawVariants
    let tooManyData = try JSONSerialization.data(withJSONObject: tooManyObject)
    #expect(tooManyData.count < ReelInspectionPolicy.maximumJSONBytes)
    #expect(throws: (any Error).self) { try ReelInspectionPolicy.decodePersistedInfo(tooManyData) }
    #expect(throws: (any Error).self) {
        try ReelInspectionPolicy.decodePersistedInfo(Data(repeating: 0x20, count: ReelInspectionPolicy.maximumJSONBytes + 1))
    }
}

@Test func internalReelMetadataNeverSelectsItsInspectionFolderAsOutput() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("KioReelInspection-(UUID().uuidString)", isDirectory: true)
    let inspectionFolder = support.appendingPathComponent("ReelInspection", isDirectory: true)
    let downloads = support.appendingPathComponent("Downloads/Kio", isDirectory: true)
    try FileManager.default.createDirectory(at: inspectionFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: support) }
    let artifact = ArtifactRef(displayName: "inspection.kio-reel-info", kind: .other,
        fileURL: inspectionFolder.appendingPathComponent("inspection.kio-reel-info"), sizeBytes: 10,
        role: .internalIntermediate)
    #expect(try OutputLocation.resolvedDestinationFolder(for: [artifact], customFolder: nil, defaultFolder: downloads) == downloads)
    #expect(try OutputLocation.resolvedDestinationFolder(for: [artifact], customFolder: downloads, defaultFolder: support) == downloads)
}

@Test func reelInspectionCommandRequestsOnlyCompactJSONAndKeepsHelperIsolation() throws {
    let url = URL(string: "https://media.example/watch")!
    let arguments = try ReelCommandBuilder.inspection(url: url, denoURL: URL(fileURLWithPath: "/app/Reel/deno"))
    #expect(arguments.contains("--print"))
    #expect(arguments.contains(ReelCommandBuilder.inspectionJSONTemplate))
    #expect(arguments.contains("--skip-download"))
    #expect(arguments.contains("--no-cookies"))
    #expect(arguments.contains("--no-cookies-from-browser"))
    #expect(arguments.contains("--no-plugin-dirs"))
    #expect(arguments.contains("--no-remote-components"))
    #expect(arguments.contains("--ignore-config"))
    #expect(arguments.contains("deno:/app/Reel/deno"))
    #expect(!arguments.contains("--dump-single-json"))
    #expect(arguments.last == url.absoluteString)
}

@Test func reelBoundedProcessOutputReportsTruncationAndKeepsDrainingCount() {
    var accumulator = ReelProcessOutputAccumulator(maximumBytes: 5)
    accumulator.append(Data("abc".utf8))
    accumulator.append(Data("defgh".utf8))
    let output = accumulator.output
    #expect(String(decoding: output.data, as: UTF8.self) == "abcde")
    #expect(output.byteCount == 8)
    #expect(output.truncated)

    var exactLimit = ReelProcessOutputAccumulator(maximumBytes: 3)
    exactLimit.append(Data("abc".utf8))
    #expect(exactLimit.output.byteCount == 3)
    #expect(!exactLimit.output.truncated)
}

@Test func reelHelperTrustFailureClassificationAndPreparedBinaryChecksAreBounded() throws {
    #expect(ReelHelperFailureKind.classify("ERROR: DRM protected / Widevine") == .drmProtected)
    #expect(ReelHelperFailureKind.classify("Please sign in to continue") == .authenticationRequired)
    #expect(ReelHelperFailureKind.classify("network timeout") == .timeout)
    #expect(ReelHelperFailureKind.unsupportedExtractor.allowsFallback)
    #expect(ReelHelperFailureKind.extractionFailure.allowsFallback)
    #expect(ReelHelperFailureKind.noMatchingSource.allowsFallback)
    #expect(!ReelHelperFailureKind.sourceSelectionFailure.allowsFallback)
    #expect(!ReelHelperFailureKind.audioTrackUnavailable.allowsFallback)
    #expect(!ReelHelperFailureKind.drmProtected.allowsFallback)
    #expect(!ReelHelperFailureKind.authenticationRequired.allowsFallback)
    #expect(!ReelHelperFailureKind.timeout.allowsFallback)
    #expect(!ReelHelperFailureKind.unsafeRedirect.allowsFallback)
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

@Test func reelMediaDiagnosticsAreCategorizedSanitizedAndResolutionAware() {
    #expect(ReelMediaDiagnostic.classify("Stream map '0:a:0' matches no streams.") == .noAudioStream)
    #expect(ReelMediaDiagnostic.classify("Stream map '0:v:0' matches no streams.") == .noVideoStream)
    #expect(ReelMediaDiagnostic.classify("Unknown encoder 'libnotavailable'") == .encoder)
    #expect(ReelMediaDiagnostic.classify("Error while encoding with VideoToolbox") == .videoToolbox)

    let excerpt = ReelMediaDiagnostic.sanitizedExcerpt("Error opening /Users/joe/private/source.mp4: failed at https://private.example/path\n")
    #expect(excerpt?.contains("/Users/joe") == false)
    #expect(excerpt?.contains("private.example") == false)
    #expect(excerpt?.contains("<path>") == true)
    let spacedPath = ReelMediaDiagnostic.sanitizedExcerpt("Error opening /Users/joe/Private Folder/source.mp4: invalid stream\n")
    #expect(spacedPath?.contains("Private Folder") == false)
    #expect(spacedPath?.contains("source.mp4") == false)

    let failure = ReelMediaProcessFailure(kind: .videoToolbox, exitStatus: 218,
        operationCategory: "video conversion", sourceCodec: "av1", targetFormat: "MP4 (H.264/AAC)",
        diagnosticExcerpt: "VideoToolbox failed")
    #expect(failure.diagnosticSummary.contains("exit=218"))
    #expect(failure.diagnosticSummary.contains("sourceCodec=av1"))
    #expect(failure.diagnosticSummary.contains("target=MP4"))

    #expect(BundledMediaRuntime.videoBitrate(forHeight: 360).maximumKbps == 900)
    #expect(BundledMediaRuntime.videoBitrate(forHeight: 720).maximumKbps == 1_800)
    #expect(BundledMediaRuntime.videoBitrate(forHeight: 1080).maximumKbps == 4_500)
    #expect(BundledMediaRuntime.videoBitrate(forHeight: 1440).maximumKbps == 7_500)
    #expect(BundledMediaRuntime.videoBitrate(forHeight: 2160).maximumKbps == 12_000)
}

@Test func reelManifestPinsBundledRuntimeVersionsPathsAndLicenses() throws {
    let manifest = try #require(ReelRuntimeManifest.bundled)
    #expect(manifest.architecture == "arm64-apple-darwin")
    #expect(manifest.component("yt-dlp")?.version == "2026.08.19")
    #expect(manifest.component("deno")?.version == "2.9.7")
    #expect(manifest.component("ffmpeg")?.license.contains("LGPL") == true)
    #expect(manifest.component("lame")?.license == "LGPL-2.0-or-later")
    #expect(manifest.component("openh264") == nil)
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
    #expect(try ReelOutputPolicy.currentSize(root: root, maximumBytes: 9) == 9)
    do {
        _ = try ReelOutputPolicy.currentSize(root: root, maximumBytes: 8)
        Issue.record("The live output monitor must enforce the byte cap while the helper is still running.")
    } catch { #expect(error.localizedDescription.contains("size limit")) }
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
