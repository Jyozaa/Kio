@preconcurrency import Speech
import AVFoundation
import Foundation
import KioCore

public enum EchoWorkflow {
    fileprivate struct Segment: Sendable {
        let start: TimeInterval
        let duration: TimeInterval
        let text: String
    }
    fileprivate struct Transcript: Sendable {
        let text: String
        let segments: [Segment]
    }

    public static func execute(_ operation: ToolOperation, inputs: [ArtifactRef]) async throws -> [ArtifactRef] {
        if operation == .convertAudio {
            guard inputs.count == 1, let input = inputs.first, input.kind == .audio,
                  input.sizeBytes <= 1_000_000_000 else {
                throw KioFailure.invalidInput("Echo's audio conversion needs one audio file up to 1 GB.")
            }
            let output = try OutputLocation.makeURL(for: [input], baseName: base(input.displayName) + "-Converted", fileExtension: "m4a")
            let temporary = OutputLocation.temporaryURL(beside: output)
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                let source = try AVAudioFile(forReading: input.fileURL)
                let sourceFormat = source.processingFormat
                guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
                    throw KioFailure.invalidInput("This file does not contain a readable audio track.")
                }
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                               AVSampleRateKey: sourceFormat.sampleRate,
                                               AVNumberOfChannelsKey: Int(sourceFormat.channelCount),
                                               AVEncoderBitRateKey: 128_000]
                let destination = try AVAudioFile(forWriting: temporary, settings: settings)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 8_192) else {
                    throw KioFailure.processing("Kio couldn't prepare a bounded audio conversion buffer.")
                }
                while source.framePosition < source.length {
                    try Task.checkCancellation()
                    try source.read(into: buffer, frameCount: min(buffer.frameCapacity, AVAudioFrameCount(source.length - source.framePosition)))
                    guard buffer.frameLength > 0 else { break }
                    try destination.write(from: buffer)
                }
            }
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: temporary.path),
                  try await AVURLAsset(url: temporary).load(.tracks).contains(where: { $0.mediaType == .audio }) else {
                throw KioFailure.verification("The converted M4A file could not be verified.")
            }
            try OutputLocation.commit(temporary, to: output)
            return [try ArtifactRef.inspect(output, parentID: input.id)
                .withVerificationNote("Converted to M4A with native Apple media tools. The original remains unchanged.")]
        }
        guard [.transcribeAudio, .generateSubtitles].contains(operation), inputs.count == 1,
              let input = inputs.first, input.kind == .audio, input.sizeBytes <= 1_000_000_000 else {
            throw KioFailure.invalidInput("Echo's local transcription needs one audio file up to 1 GB.")
        }
        let transcript = try await recognize(input.fileURL)
        try Task.checkCancellation()
        if operation == .transcribeAudio {
            let body = transcript.segments.map { segment in
                "[\(timestamp(segment.start))–\(timestamp(segment.start + segment.duration))] \(segment.text)"
            }.joined(separator: "\n")
            let markdown = "# Transcript\n\n\(body.isEmpty ? transcript.text : body)\n"
            let output = try OutputLocation.makeURL(for: [input], baseName: base(input.displayName) + "-transcript", fileExtension: "md")
            try write(Data(markdown.utf8), to: output)
            return [try ArtifactRef.inspect(output, parentID: input.id)
                .withVerificationNote("Transcribed with Apple's on-device speech recognizer. Audio stayed on this Mac.")]
        }
        let srtURL = try OutputLocation.makeURL(for: [input], baseName: base(input.displayName), fileExtension: "srt")
        let vttURL = try OutputLocation.makeURL(for: [input], baseName: base(input.displayName), fileExtension: "vtt")
        let srt = transcript.segments.enumerated().map { index, segment in
            "\(index + 1)\n\(subtitleTime(segment.start, separator: ",")) --> \(subtitleTime(segment.start + segment.duration, separator: ","))\n\(segment.text)"
        }.joined(separator: "\n\n") + "\n"
        let vtt = "WEBVTT\n\n" + transcript.segments.map { segment in
            "\(subtitleTime(segment.start, separator: ".")) --> \(subtitleTime(segment.start + segment.duration, separator: "."))\n\(segment.text)"
        }.joined(separator: "\n\n") + "\n"
        try write(Data(srt.utf8), to: srtURL)
        try write(Data(vtt.utf8), to: vttURL)
        let note = "Generated from Apple's on-device speech recognition. Audio stayed on this Mac."
        return [try ArtifactRef.inspect(srtURL, parentID: input.id).withVerificationNote(note),
                try ArtifactRef.inspect(vttURL, parentID: input.id).withVerificationNote(note)]
    }

    private static func recognize(_ url: URL) async throws -> Transcript {
        try Task.checkCancellation()
        let status = await authorizationStatus()
        guard status == .authorized else {
            throw KioFailure.unsupported(status == .denied || status == .restricted
                ? "Enable Speech Recognition for Kio in System Settings to transcribe audio."
                : "Speech Recognition permission is required for this transcription.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.supportsOnDeviceRecognition else {
            throw KioFailure.unsupported("Apple's on-device speech recognizer isn't available for the current language on this Mac.")
        }
        let holder = RecognitionTaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let request = SFSpeechURLRecognitionRequest(url: url)
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = false
                request.addsPunctuation = true
                let gate = RecognitionCompletion()
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        if holder.wasCancelled {
                            gate.finishCancelled(continuation)
                        } else {
                            gate.finish(continuation, result: .failure(.processing(error.localizedDescription)))
                        }
                    } else if let result, result.isFinal {
                        let segments = result.bestTranscription.segments.map {
                            Segment(start: $0.timestamp, duration: $0.duration, text: $0.substring)
                        }
                        gate.finish(continuation, result: .success(Transcript(text: result.bestTranscription.formattedString, segments: segments)))
                    }
                }
                holder.install(task)
            }
        } onCancel: {
            holder.cancel()
        }
    }

    private static func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private static func write(_ data: Data, to output: URL) throws {
        let temp = OutputLocation.temporaryURL(beside: output)
        defer { try? FileManager.default.removeItem(at: temp) }
        try data.write(to: temp, options: .atomic)
        try OutputLocation.commit(temp, to: output)
    }
    private static func base(_ name: String) -> String { URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent }
    private static func timestamp(_ seconds: TimeInterval) -> String { String(format: "%.2f s", seconds) }
    private static func subtitleTime(_ seconds: TimeInterval, separator: String) -> String {
        let milliseconds = max(0, Int((seconds * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let secondsPart = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secondsPart, separator, remainder)
    }
}

private final class RecognitionTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false
    func install(_ task: SFSpeechRecognitionTask) {
        lock.lock(); self.task = task; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { task.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock()
        current?.cancel()
    }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private final class RecognitionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    func finish(_ continuation: CheckedContinuation<EchoWorkflow.Transcript, any Error>, result: Result<EchoWorkflow.Transcript, KioFailure>) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        lock.unlock()
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
    func finishCancelled(_ continuation: CheckedContinuation<EchoWorkflow.Transcript, any Error>) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        lock.unlock()
        continuation.resume(throwing: CancellationError())
    }
}
