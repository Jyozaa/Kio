import Foundation
import KioCore

public enum ReelVideoContainer: String, Sendable { case mp4, webm, mkv, mov }

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
        case .m4a: return (container.contains("mp4") || container.contains("mov")) && !audio.isEmpty
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
        case .mov: return mux.contains("mov")
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
        let result = try await run(executable, arguments: args, timeoutSeconds: timeoutSeconds, maximumOutputBytes: 2_000_000)
        guard let info = try? JSONDecoder().decode(MediaProbeInfo.self, from: result.stdout),
              !info.streams.isEmpty else {
            throw KioFailure.verification("ffprobe could not read valid media stream metadata.")
        }
        return info
    }

    public static func transcodeAudio(_ input: URL, to output: URL, format: AudioTargetFormat,
                                      timeoutSeconds: TimeInterval = 4 * 60 * 60,
                                      runtimeRoot: URL? = nil) async throws {
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
                          monitorOutputURL: output, maximumOutputFileBytes: maximumMediaBytes)
    }

    public static func transcodeMP4(_ input: URL, to output: URL,
                                    timeoutSeconds: TimeInterval = 4 * 60 * 60) async throws {
        let args = ["-nostdin", "-hide_banner", "-v", "error", "-y", "-i", input.path,
                    "-map", "0:v:0", "-map", "0:a?", "-c:v", "h264_videotoolbox", "-b:v", "5M", "-maxrate", "8M",
                    "-bufsize", "10M", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-f", "mp4", output.path]
        _ = try await run(ffmpegURL, arguments: args, timeoutSeconds: timeoutSeconds, maximumOutputBytes: 64_000,
                          monitorOutputURL: output, maximumOutputFileBytes: maximumMediaBytes)
    }

    public static func transcodeVideo(_ input: URL, to output: URL, container: ReelVideoContainer,
                                      maximumHeight: Int? = nil,
                                      timeoutSeconds: TimeInterval = 4 * 60 * 60,
                                      runtimeRoot: URL? = nil) async throws {
        if container == .webm {
            throw KioFailure.unsupported("This Mac's bundled media runtime can preserve compatible WebM streams, but cannot re-encode them to WebM.")
        }
        let codecArgs: [String]
        let muxer: String
        switch container {
        case .mp4:
            codecArgs = ["-c:v", "h264_videotoolbox", "-b:v", "5M", "-maxrate", "8M", "-bufsize", "10M",
                         "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
            muxer = "mp4"
        case .webm:
            codecArgs = ["-c", "copy"]
            muxer = "webm"
        case .mkv:
            codecArgs = maximumHeight == nil
                ? ["-c", "copy"]
                : ["-c:v", "h264_videotoolbox", "-b:v", "5M", "-maxrate", "8M", "-bufsize", "10M",
                   "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
            muxer = "matroska"
        case .mov:
            codecArgs = ["-c:v", "h264_videotoolbox", "-b:v", "5M", "-maxrate", "8M", "-bufsize", "10M",
                         "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
            muxer = "mov"
        }
        let heightFilter = maximumHeight.map { ["-vf", "scale=-2:min(ih\\,\($0))"] } ?? []
        let args = ["-nostdin", "-hide_banner", "-v", "error", "-y", "-i", input.path]
            + heightFilter + ["-map", "0:v:0", "-map", "0:a?"] + codecArgs + ["-f", muxer, output.path]
        let executable = runtimeRoot.flatMap { ReelRuntime.url(for: "ffmpeg", in: $0) } ?? ffmpegURL
        _ = try await run(executable, arguments: args, timeoutSeconds: timeoutSeconds, maximumOutputBytes: 64_000,
                          monitorOutputURL: output, maximumOutputFileBytes: maximumMediaBytes)
    }

    private static func run(_ executable: URL, arguments: [String], timeoutSeconds: TimeInterval,
                            maximumOutputBytes: Int, monitorOutputURL: URL? = nil,
                            maximumOutputFileBytes: Int64 = maximumMediaBytes) async throws -> (stdout: Data, stderr: Data) {
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
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else {
                    process.terminate()
                    throw KioFailure.processing("The bundled media tool exceeded its processing time limit.")
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
            _ = await stderrTask.value
            if error is CancellationError { throw CancellationError() }
            throw error
        }
        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value
        guard !outputLimitExceeded else {
            throw KioFailure.verification("The media conversion stopped because its output exceeded Kio's 8 GB file limit.")
        }
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderr.0, as: UTF8.self).lowercased()
            if detail.contains("matches no streams") || detail.contains("does not contain any stream") || detail.contains("stream map") {
                throw KioFailure.invalidInput("This source does not contain the requested audio track.")
            }
            if detail.contains("unknown decoder") || detail.contains("decoder .* not found") || detail.contains("unsupported codec") {
                throw KioFailure.unsupported("The bundled FFmpeg runtime doesn't support this source codec.")
            }
            throw KioFailure.processing("The bundled media conversion failed. Check that the source is readable and uses a supported codec.")
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
