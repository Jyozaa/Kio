import Foundation
import KioCore
import os

public enum ReelVideoContainer: String, Sendable { case mp4, webm, mkv, mov }

public enum ReelMediaToolFailureKind: String, Sendable, Equatable {
    case decoder, encoder, noVideoStream, noAudioStream, noStreams, filter, muxer, videoToolbox, library, pixelFormat
    case timeout, outputLimit, verification, process
}

public enum ReelMediaDiagnostic {
    public static func classify(_ stderr: String) -> ReelMediaToolFailureKind {
        let value = stderr.lowercased()
        if value.contains("videotoolbox") || value.contains("vt_encoder") || value.contains("hardware encoder") { return .videoToolbox }
        if value.contains("matches no streams") || value.contains("stream map") {
            if value.contains(":a") || value.contains("audio") { return .noAudioStream }
            if value.contains(":v") || value.contains("video") { return .noVideoStream }
            return .noStreams
        }
        if value.contains("does not contain any stream") || value.contains("no streams found") { return .noStreams }
        if value.contains("unknown decoder") || value.contains("decoder not found") || value.contains("failed to open decoder") { return .decoder }
        if value.contains("unknown encoder") || value.contains("encoder not found") || value.contains("failed to open encoder") { return .encoder }
        if value.contains("no such filter") || value.contains("filter not found") || value.contains("error reinitializing filters") { return .filter }
        if value.contains("unknown format") || value.contains("muxer not found") || value.contains("requested output format") { return .muxer }
        if value.contains("library not loaded") || value.contains("image not found") || value.contains("dylib") { return .library }
        if value.contains("pixel format") || value.contains("pix_fmt") || value.contains("unsupported pixel") { return .pixelFormat }
        if value.contains("timed out") || value.contains("timeout") { return .timeout }
        if value.contains("file size limit") || value.contains("no space left") || value.contains("output limit") { return .outputLimit }
        if value.contains("invalid data found") || value.contains("could not find codec parameters") || value.contains("moov atom not found") { return .verification }
        return .process
    }

    public static func sanitizedExcerpt(_ stderr: String, maximumCharacters: Int = 180) -> String? {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        let relevant = lines.filter {
            let value = $0.lowercased()
            return value.contains("error") || value.contains("failed") || value.contains("not found") || value.contains("invalid")
        }
        let selected = Array((relevant.isEmpty ? lines : relevant).suffix(3))
        let sanitized = selected.map { line in
            line.replacingOccurrences(of: #"https?://\S+"#, with: "<URL>", options: .regularExpression)
                .replacingOccurrences(of: #"(?:[A-Za-z]:)?/[^\s,:;]+"#, with: "<path>", options: .regularExpression)
                .unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !sanitized.isEmpty else { return nil }
        return String(sanitized.joined(separator: " | ").suffix(max(1, maximumCharacters)))
    }

    public static func userMessage(for kind: ReelMediaToolFailureKind, stderr: String) -> String {
        let detail = sanitizedExcerpt(stderr).map { " Detail: \($0)" } ?? ""
        return switch kind {
        case .decoder: "The bundled media runtime has no decoder for this source codec.\(detail)"
        case .encoder: "The bundled media runtime has no permitted encoder for this output.\(detail)"
        case .noVideoStream: "The source has no video stream for this operation.\(detail)"
        case .noAudioStream: "The source has no audio stream for this operation.\(detail)"
        case .noStreams: "The source has no stream matching the requested audio or video output.\(detail)"
        case .filter: "The bundled media runtime couldn't apply the requested media filter.\(detail)"
        case .muxer: "The bundled media runtime can't write the requested output container.\(detail)"
        case .videoToolbox: "macOS VideoToolbox couldn't encode this video.\(detail)"
        case .library: "A required library for the bundled media runtime is unavailable.\(detail)"
        case .pixelFormat: "The bundled media runtime can't use a compatible pixel format for this source.\(detail)"
        case .timeout: "The bundled media runtime exceeded its configured processing timeout.\(detail)"
        case .outputLimit: "The media output reached Kio's configured file-size limit.\(detail)"
        case .verification: "The media output couldn't be verified as a valid file.\(detail)"
        case .process: "The bundled media conversion failed.\(detail)"
        }
    }
}

public struct ReelMediaProcessFailure: Error, LocalizedError, Sendable {
    public let kind: ReelMediaToolFailureKind
    public let exitStatus: Int32?
    public let operationCategory: String
    public let sourceCodec: String?
    public let targetFormat: String?
    public let diagnosticExcerpt: String?

    public var errorDescription: String? { ReelMediaDiagnostic.userMessage(for: kind, stderr: diagnosticExcerpt ?? "") }

    public var diagnosticSummary: String {
        let context = ["operation=\(operationCategory)",
                       exitStatus.map { "exit=\($0)" },
                       sourceCodec.map { "sourceCodec=\($0)" },
                       targetFormat.map { "target=\($0)" },
                       diagnosticExcerpt.map { "stderr=\($0)" }].compactMap { $0 }
        return "Reel media failure [\(kind.rawValue)]: " + context.joined(separator: ", ")
    }
}

public struct MediaStreamInfo: Decodable, Sendable {
    public let codec_type: String
    public let codec_name: String?
    public let width: Int?
    public let height: Int?
    public let sample_rate: String?
    public let channels: Int?
}

public struct MediaProbeInfo: Decodable, Sendable {
    public struct Format: Decodable, Sendable { public let duration: String?; public let format_name: String? }
    public let streams: [MediaStreamInfo]
    public let format: Format?

    public var duration: Double? { format?.duration.flatMap(Double.init) }
    public var hasAudio: Bool { streams.contains { $0.codec_type == "audio" } }
    public var hasVideo: Bool { streams.contains { $0.codec_type == "video" } }
    public var isMP4Compatible: Bool {
        guard format?.format_name?.contains("mp4") == true || format?.format_name?.contains("mov") == true,
              let video = streams.first(where: { $0.codec_type == "video" }), video.codec_name == "h264" else { return false }
        return !hasAudio || streams.first(where: { $0.codec_type == "audio" })?.codec_name == "aac"
    }

    public func isCompatibleAudio(with target: AudioTargetFormat) -> Bool {
        guard !hasVideo, let audio = streams.first(where: { $0.codec_type == "audio" })?.codec_name?.lowercased(),
              let container = format?.format_name?.lowercased() else { return false }
        switch target {
        case .mp3: return audio == "mp3" && container.contains("mp3")
        case .m4a: return (container.contains("mp4") || container.contains("mov")) && ["aac", "alac"].contains(audio)
        case .wav: return container.contains("wav") && audio.hasPrefix("pcm_")
        case .flac: return container.contains("flac") && audio == "flac"
        }
    }

    public func isCompatible(with container: ReelVideoContainer) -> Bool {
        let mux = format?.format_name?.lowercased() ?? ""
        switch container {
        case .mp4: return isMP4Compatible
        case .webm:
            let video = streams.first(where: { $0.codec_type == "video" })?.codec_name
            let audio = streams.first(where: { $0.codec_type == "audio" })?.codec_name
            return mux.contains("webm") && ["vp8", "vp9", "av1"].contains(video ?? "")
                && (!hasAudio || ["opus", "vorbis"].contains(audio ?? ""))
        case .mkv: return mux.contains("matroska")
        case .mov:
            guard mux.contains("mov") || mux.contains("quicktime"),
                  let video = streams.first(where: { $0.codec_type == "video" })?.codec_name?.lowercased(),
                  ["h264", "hevc", "prores", "mpeg4"].contains(video) else { return false }
            let audio = streams.first(where: { $0.codec_type == "audio" })?.codec_name?.lowercased()
            return !hasAudio || audio == "aac" || audio == "alac" || audio?.hasPrefix("pcm_") == true
        }
    }
}

/// Shared access to the checksum-pinned Reel media tools. Callers provide typed
/// operations; no model-produced command string is ever evaluated by a shell.
public enum BundledMediaRuntime {
    public static let maximumMediaBytes: Int64 = 8 * 1_024 * 1_024 * 1_024

    public static var ffmpegURL: URL {
        ReelRuntime.url(for: "ffmpeg") ?? ReelRuntime.bundleURL.appendingPathComponent("ffmpeg/bin/ffmpeg")
    }
    public static var ffprobeURL: URL {
        ReelRuntime.url(for: "ffprobe") ?? ReelRuntime.bundleURL.appendingPathComponent("ffmpeg/bin/ffprobe")
    }

    public static func probe(_ url: URL, timeoutSeconds: TimeInterval = 45,
                             runtimeRoot: URL? = nil) async throws -> MediaProbeInfo {
        let args = ["-v", "error", "-show_entries", "format=duration,format_name:stream=codec_type,codec_name,width,height,sample_rate,channels", "-of", "json", url.path]
        let executable = runtimeRoot.flatMap { ReelRuntime.url(for: "ffprobe", in: $0) } ?? ffprobeURL
        let result = try await run(executable, arguments: args, timeoutSeconds: timeoutSeconds, maximumOutputBytes: 2_000_000,
                                   operationCategory: "media probe")
        guard let info = try? JSONDecoder().decode(MediaProbeInfo.self, from: result.stdout),
              !info.streams.isEmpty else {
            throw KioFailure.verification("ffprobe could not read valid media stream metadata.")
        }
        return info
    }

    public static func transcodeAudio(_ input: URL, to output: URL, format: AudioTargetFormat,
                                      timeoutSeconds: TimeInterval = 4 * 60 * 60,
                                      runtimeRoot: URL? = nil, sourceCodec: String? = nil) async throws {
        let args: [String]
        switch format {
        case .mp3:
            args = ["-i", input.path, "-map", "0:a:0", "-vn", "-c:a", "libmp3lame", "-q:a", "2", "-f", "mp3", output.path]
        case .m4a:
            args = ["-i", input.path, "-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "192k", "-f", "ipod", output.path]
        case .wav:
            args = ["-i", input.path, "-map", "0:a:0", "-vn", "-c:a", "pcm_s16le", "-f", "wav", output.path]
        case .flac:
            args = ["-i", input.path, "-map", "0:a:0", "-vn", "-c:a", "flac", "-compression_level", "5", "-f", "flac", output.path]
        }
        let executable = runtimeRoot.flatMap { ReelRuntime.url(for: "ffmpeg", in: $0) } ?? ffmpegURL
        _ = try await run(executable, arguments: ["-nostdin", "-hide_banner", "-v", "error", "-y"] + args,
                          timeoutSeconds: timeoutSeconds, maximumOutputBytes: 64_000,
                          monitorOutputURL: output, maximumOutputFileBytes: maximumMediaBytes,
                          operationCategory: "audio conversion", sourceCodec: sourceCodec,
                          targetFormat: audioTargetDescription(format))
    }

    public static func transcodeMP4(_ input: URL, to output: URL,
                                    timeoutSeconds: TimeInterval = 4 * 60 * 60) async throws {
        try await transcodeVideo(input, to: output, container: .mp4, timeoutSeconds: timeoutSeconds)
    }

    public static func transcodeVideo(_ input: URL, to output: URL, container: ReelVideoContainer,
                                      maximumHeight: Int? = nil,
                                      timeoutSeconds: TimeInterval = 4 * 60 * 60,
                                      runtimeRoot: URL? = nil) async throws {
        let source = try await probe(input, runtimeRoot: runtimeRoot)
        guard source.hasVideo,
              let sourceHeight = source.streams.first(where: { $0.codec_type == "video" })?.height,
              sourceHeight > 0 else { throw KioFailure.verification("The input has no readable video dimensions.") }
        let bitrate = videoBitrate(forHeight: maximumHeight ?? sourceHeight)
        let maximumRate = bitrate.maximumKbps * 3 / 2
        let bufferSize = bitrate.maximumKbps * 2
        let needsResize = maximumHeight.map { sourceHeight > $0 } ?? false
        let codecArgs: [String]
        let muxer: String
        switch container {
        case .mp4:
            codecArgs = !needsResize && source.isCompatible(with: .mp4) ? ["-c", "copy"] : ["-c:v", "h264_videotoolbox", "-b:v", "\(bitrate.maximumKbps)k", "-maxrate", "\(maximumRate)k", "-bufsize", "\(bufferSize)k",
                         "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "\(bitrate.audioKbps)k", "-movflags", "+faststart"]
            muxer = "mp4"
        case .webm:
            guard !needsResize, source.isCompatible(with: .webm) else {
                throw KioFailure.unsupported("This Mac's bundled media runtime can only preserve WebM with compatible existing video and audio codecs.")
            }
            codecArgs = ["-c", "copy"]
            muxer = "webm"
        case .mkv:
            codecArgs = !needsResize ? ["-c", "copy"]
                : ["-c:v", "h264_videotoolbox", "-b:v", "\(bitrate.maximumKbps)k", "-maxrate", "\(maximumRate)k", "-bufsize", "\(bufferSize)k",
                   "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "\(bitrate.audioKbps)k"]
            muxer = "matroska"
        case .mov:
            codecArgs = !needsResize && source.isCompatible(with: .mov) ? ["-c", "copy"] : ["-c:v", "h264_videotoolbox", "-b:v", "\(bitrate.maximumKbps)k", "-maxrate", "\(maximumRate)k", "-bufsize", "\(bufferSize)k",
                         "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "\(bitrate.audioKbps)k"]
            muxer = "mov"
        }
        let heightFilter = needsResize ? maximumHeight.map { ["-vf", "scale=-2:min(ih\\,\($0))"] } ?? [] : []
        let outputCodec = codecArgs.contains("h264_videotoolbox") ? "H.264/AAC" : "stream copy"
        let sourceCodec = source.streams.first(where: { $0.codec_type == "video" })?.codec_name
        let targetFormat = "\(container.rawValue.uppercased()) (\(outputCodec))"
        let args = ["-nostdin", "-hide_banner", "-v", "error", "-y", "-i", input.path]
            + heightFilter + ["-map", "0:v:0", "-map", "0:a?"] + codecArgs + ["-f", muxer, output.path]
        let executable = runtimeRoot.flatMap { ReelRuntime.url(for: "ffmpeg", in: $0) } ?? ffmpegURL
        do {
            _ = try await run(executable, arguments: args, timeoutSeconds: timeoutSeconds, maximumOutputBytes: 64_000,
                              monitorOutputURL: output, maximumOutputFileBytes: maximumMediaBytes,
                              operationCategory: "video conversion", sourceCodec: sourceCodec, targetFormat: targetFormat)
        } catch {
            guard codecArgs.contains("h264_videotoolbox"),
                  ReelMediaDiagnostic.classify(error.localizedDescription) == .videoToolbox,
                  let softwareEncoder = await permittedSoftwareH264Encoder(runtimeRoot: runtimeRoot) else { throw error }
            let softwareArgs = args.enumerated().map { index, value in
                value == "h264_videotoolbox" ? softwareEncoder : value
            }
            _ = try await run(executable, arguments: softwareArgs, timeoutSeconds: timeoutSeconds, maximumOutputBytes: 64_000,
                              monitorOutputURL: output, maximumOutputFileBytes: maximumMediaBytes,
                              operationCategory: "video conversion software fallback", sourceCodec: sourceCodec,
                              targetFormat: "\(container.rawValue.uppercased()) (OpenH264)")
        }
    }

    public static func videoBitrate(forHeight height: Int) -> (maximumKbps: Int, audioKbps: Int) {
        switch height {
        case ...480: (900, 128)
        case 481...720: (1_800, 160)
        case 721...1080: (4_500, 192)
        case 1081...1440: (7_500, 192)
        default: (12_000, 256)
        }
    }

    private static func permittedSoftwareH264Encoder(runtimeRoot: URL?) async -> String? {
        guard let manifest = ReelRuntimeManifest.bundled,
              manifest.component("ffmpeg")?.license.localizedCaseInsensitiveContains("LGPL") == true,
              let encoderComponent = manifest.component("openh264"),
              encoderComponent.license.localizedCaseInsensitiveContains("LGPL") else { return nil }
        let executable = runtimeRoot.flatMap { ReelRuntime.url(for: "ffmpeg", in: $0) } ?? ffmpegURL
        guard let output = try? await run(executable, arguments: ["-hide_banner", "-encoders"],
                                          timeoutSeconds: 10, maximumOutputBytes: 128_000),
              output.stdout.count <= 128_000 else { return nil }
        let list = String(decoding: output.stdout, as: UTF8.self)
        return list.contains("libopenh264") ? "libopenh264" : nil
    }

    private static let logger = Logger(subsystem: "app.kio.mac", category: "Reel.MediaRuntime")

    private static func audioTargetDescription(_ format: AudioTargetFormat) -> String {
        switch format {
        case .mp3: "MP3"
        case .m4a: "M4A (AAC)"
        case .wav: "WAV (PCM)"
        case .flac: "FLAC"
        }
    }

    private static func run(_ executable: URL, arguments: [String], timeoutSeconds: TimeInterval,
                            maximumOutputBytes: Int, monitorOutputURL: URL? = nil,
                            maximumOutputFileBytes: Int64 = maximumMediaBytes,
                            operationCategory: String = "media process", sourceCodec: String? = nil,
                            targetFormat: String? = nil) async throws -> (stdout: Data, stderr: Data) {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw KioFailure.unsupported("Kio's pinned FFmpeg/ffprobe media runtime isn't prepared on this Mac.")
        }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else { throw KioFailure.invalidInput("The media tool timeout must be positive.") }
        let process = Process()
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do { try process.run() }
        catch { throw KioFailure.processing("Kio couldn't start its bundled media tool: \(error.localizedDescription)") }
        let stdoutTask = Task.detached { Self.readBounded(stdoutPipe.fileHandleForReading, maximumBytes: maximumOutputBytes) }
        let stderrTask = Task.detached { Self.readBounded(stderrPipe.fileHandleForReading, maximumBytes: 8_000) }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var outputLimitExceeded = false
        var timedOut = false
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else {
                    timedOut = true
                    process.terminate()
                    throw CancellationError()
                }
                if let monitorOutputURL,
                   let attributes = try? FileManager.default.attributesOfItem(atPath: monitorOutputURL.path),
                   let size = attributes[.size] as? NSNumber, size.int64Value > maximumOutputFileBytes {
                    outputLimitExceeded = true
                    process.terminate()
                    break
                }
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch {
            if process.isRunning { process.terminate() }
            try? await Task.sleep(for: .milliseconds(250))
            if process.isRunning { process.interrupt() }
            _ = await stdoutTask.value
            let stderr = await stderrTask.value
            if timedOut {
                let failure = ReelMediaProcessFailure(kind: .timeout, exitStatus: nil,
                    operationCategory: operationCategory, sourceCodec: sourceCodec, targetFormat: targetFormat,
                    diagnosticExcerpt: ReelMediaDiagnostic.sanitizedExcerpt(String(decoding: stderr.0, as: UTF8.self)))
                logger.error("\(failure.diagnosticSummary, privacy: .public)")
                throw failure
            }
            if error is CancellationError { throw CancellationError() }
            throw error
        }
        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value
        guard !outputLimitExceeded else {
            let failure = ReelMediaProcessFailure(kind: .outputLimit, exitStatus: process.terminationStatus,
                operationCategory: operationCategory, sourceCodec: sourceCodec, targetFormat: targetFormat,
                diagnosticExcerpt: "Configured file limit: \(maximumOutputFileBytes) bytes")
            logger.error("\(failure.diagnosticSummary, privacy: .public)")
            throw failure
        }
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderr.0, as: UTF8.self)
            let kind = ReelMediaDiagnostic.classify(detail)
            let failure = ReelMediaProcessFailure(kind: kind, exitStatus: process.terminationStatus,
                operationCategory: operationCategory, sourceCodec: sourceCodec, targetFormat: targetFormat,
                diagnosticExcerpt: ReelMediaDiagnostic.sanitizedExcerpt(detail))
            logger.error("\(failure.diagnosticSummary, privacy: .public)")
            throw failure
        }
        guard !stdout.1, !stderr.1 else { throw KioFailure.verification("The media tool returned more metadata than Kio accepts.") }
        return (stdout.0, stderr.0)
    }

    private static func readBounded(_ handle: FileHandle, maximumBytes: Int) -> (Data, Bool) {
        var saved = Data()
        var truncated = false
        while true {
            let chunk = handle.readData(ofLength: 16_384)
            if chunk.isEmpty { break }
            let remaining = max(0, maximumBytes - saved.count)
            if remaining > 0 { saved.append(chunk.prefix(remaining)) }
            if chunk.count > remaining { truncated = true }
        }
        return (saved, truncated)
    }
}
