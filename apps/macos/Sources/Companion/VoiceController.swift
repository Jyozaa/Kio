import AVFoundation
import CompanionCore
import CryptoKit
import Foundation

@MainActor
final class VoiceController: ObservableObject {
    @Published var state = VoiceState()
    @Published var transcript = ""
    @Published var audioLevel = 0.0
    var onTranscript: ((String) -> Void)?
    var onStableClause: ((String) -> Void)?
    private var recorder: AVAudioRecorder?
    private var process: Process?
    private var recordingDirectory: URL?
    private var limitTask: Task<Void, Never>?
    private var partialTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var silenceDetector: SpeechSilenceDetector?
    private var streamMeterEngine: AVAudioEngine?
    private var streamMeter: StreamingAudioLevel?
    private var streamLevelDB = -160.0
    private var streamingMode = false
    private var streamingTranscript = ""
    private var streamingAssembler = StreamingTranscriptAssembler()
    private var streamingDetector = StableTranscriptDetector()
    private let digest = "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f"

    init() { Task.detached { VoiceTemporaryFiles.removeAbandoned() } }

    func begin() {
        guard ![.permission, .listening, .transcribing].contains(state.phase) else { return }
        transcript = ""
        audioLevel = 0
        let token = state.begin()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRecording(token: token)
        case .notDetermined:
            Task {
                let permitted = await AVCaptureDevice.requestAccess(for: .audio)
                guard token == state.generation else { return }
                guard permitted else {
                    state.fail("Microphone access is off. Enable Kio in System Settings → Privacy & Security → Microphone.", token: token)
                    return
                }
                startRecording(token: token)
            }
        case .denied:
            state.fail("Microphone access is off. Enable Kio in System Settings → Privacy & Security → Microphone.", token: token)
        case .restricted:
            state.fail("Microphone access is restricted on this Mac.", token: token)
        @unknown default:
            state.fail("Microphone authorization is unavailable.", token: token)
        }
    }

    private func startRecording(token: UUID) {
        guard token == state.generation else { return }
        guard AVCaptureDevice.default(for: .audio) != nil else {
            state.fail("No microphone is available.", token: token); return
        }
        let model = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kio/models/stt/ggml-tiny.en.bin")
        if let stream = HelperConfiguration.streamingSttExecutable,
           FileManager.default.fileExists(atPath: model.path) {
            startStreaming(token: token, executable: stream, model: model)
            return
        }
        do {
            let directory = try VoiceTemporaryFiles.create()
            recordingDirectory = directory
            let recorder = try AVAudioRecorder(url: directory.appendingPathComponent("input.wav"), settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ])
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            silenceDetector = SpeechSilenceDetector()
            state.recording(token)
            limitTask = Task { await monitorSilence(token: token) }
            partialTask = Task { await monitorPartials(token: token, audioURL: directory.appendingPathComponent("input.wav")) }
        } catch { cleanup(); state.fail("Could not start microphone recording.", token: token) }
    }

    private func startStreaming(token: UUID, executable: URL, model: URL) {
        do {
            try startStreamingMeter()
        } catch {
            state.fail("Could not monitor microphone input.", token: token)
            return
        }
        let child = Process()
        let output = Pipe()
        child.executableURL = executable
        child.arguments = [
            "-m", model.path, "-t", "2", "--step", "500", "--length", "5000",
            "-vth", "0.6", "-l", "en", "-kc"
        ]
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
            process = child
            streamingMode = true
            streamingTranscript = ""
            streamingBytes.removeAll(keepingCapacity: true)
            streamingAssembler.reset()
            streamingDetector.reset()
            silenceDetector = SpeechSilenceDetector(
                trailingSilence: 0.9,
                maximumDuration: 30,
                noSpeechTimeout: 8
            )
            state.recording(token)
            limitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.state.generation == token else { return }
                self.release()
            }
            silenceTask = Task { await monitorStreamingSilence(token: token) }
            partialTask = Task { [weak self] in
                guard let self else { return }
                await self.consumeStreaming(output, token: token)
            }
        } catch {
            stopStreamingMeter()
            state.fail("Could not start local streaming transcription.", token: token)
        }
    }

    func release() {
        if state.phase == .permission { cancel(); return }
        guard state.phase == .listening else { return }
        if streamingMode {
            finishStreaming(token: state.generation)
            return
        }
        guard let directory = recordingDirectory else { return }
        limitTask?.cancel(); partialTask?.cancel(); recorder?.stop(); recorder = nil
        silenceDetector = nil
        audioLevel = 0
        let token = state.generation
        state.transcribing(token)
        let model = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kio/models/stt/ggml-tiny.en.bin")
        guard let executable = HelperConfiguration.sttExecutable else {
            cleanup()
            state.fail("Local voice isn't ready. Open Kio Setup and check the Voice Model.", token: token)
            return
        }
        Task {
            let expectedDigest = digest
            let valid = await Task.detached {
                guard let data = try? Data(contentsOf: model, options: .mappedIfSafe), data.count == 77704715 else { return false }
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expectedDigest
            }.value
            guard token == state.generation else { return }
            guard valid, FileManager.default.isExecutableFile(atPath: executable.path) else {
                cleanup(); state.fail("Local voice isn't ready. Open Kio Setup and check the Voice Model.", token: token); return
            }
            let child = Process(); let output = Pipe()
            child.executableURL = executable
            child.arguments = ["-m", model.path, "-f", directory.appendingPathComponent("input.wav").path, "-l", "en", "-nt", "-np"]
            child.standardOutput = output; child.standardError = FileHandle.nullDevice
            do { try child.run() } catch { cleanup(); state.fail("Could not start local transcription.", token: token); return }
            process = child
            limitTask = Task { try? await Task.sleep(for: .seconds(60)); if !Task.isCancelled, token == state.generation { cancel() } }
            let result = await Task.detached {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                child.waitUntilExit()
                return (child.terminationStatus, data.count <= 16384 ? String(data: data, encoding: .utf8) : nil)
            }.value
            // Always remove only this recording, including after cancellation/new recording.
            try? FileManager.default.removeItem(at: directory)
            guard token == state.generation else { return }
            limitTask?.cancel(); process = nil; recordingDirectory = nil
            if result.0 == 0, let text = result.1 {
                state.finish(text, token: token)
                transcript = state.transcript
                if state.phase == .review { onTranscript?(transcript) }
            }
            else { state.fail("Local transcription failed.", token: token) }
        }
    }

    func cancel() {
        state.cancel(); transcript = ""; limitTask?.cancel()
        partialTask?.cancel(); partialTask = nil
        streamingMode = false
        streamingTranscript = ""
        streamingBytes.removeAll(keepingCapacity: true)
        streamingAssembler.reset()
        streamingDetector.reset()
        silenceTask?.cancel(); silenceTask = nil
        silenceDetector = nil
        stopStreamingMeter()
        audioLevel = 0
        recorder?.stop(); recorder = nil
        if let child = process, child.isRunning {
            child.terminate()
            Task { try? await Task.sleep(for: .seconds(1)); if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        }
        process = nil; cleanup()
    }

    func markSubmitted() { state.submitted(token: state.generation) }
    private func cleanup() {
        if let directory = recordingDirectory { try? FileManager.default.removeItem(at: directory) }
        recordingDirectory = nil
    }

    private func finishStreaming(token: UUID) {
        limitTask?.cancel()
        partialTask?.cancel(); partialTask = nil
        if let child = process, child.isRunning { child.terminate() }
        process = nil
        streamingMode = false
        streamingDetector.reset()
        silenceTask?.cancel(); silenceTask = nil
        silenceDetector = nil
        stopStreamingMeter()
        audioLevel = 0
        state.transcribing(token)
        let final = streamingAssembler.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        streamingTranscript = final
        state.finish(final, token: token)
        transcript = state.transcript
        if state.phase == .review { onTranscript?(transcript) }
    }

    nonisolated private func consumeStreaming(_ output: Pipe, token: UUID) async {
        let handle = output.fileHandleForReading
        while !Task.isCancelled {
            let data = handle.availableData
            if data.isEmpty {
                await MainActor.run { [weak self] in
                    self?.handleStreamingEOF(token: token)
                }
                return
            }
            await MainActor.run { [weak self] in
                self?.acceptStreamingBytes(data, token: token)
            }
        }
    }

    private func handleStreamingEOF(token: UUID) {
        guard token == state.generation, state.phase == .listening else { return }
        limitTask?.cancel(); limitTask = nil
        silenceTask?.cancel(); silenceTask = nil
        partialTask = nil
        process = nil
        streamingMode = false
        silenceDetector = nil
        stopStreamingMeter()
        audioLevel = 0
        state.fail("Local streaming transcription stopped.", token: token)
    }

    private var streamingBytes = Data()

    private func acceptStreamingBytes(_ chunk: Data, token: UUID) {
        guard token == state.generation, state.phase == .listening else { return }
        streamingBytes.append(chunk)
        guard let decoded = String(data: streamingBytes, encoding: .utf8) else {
            if streamingBytes.count > 16384 { streamingBytes.removeAll(keepingCapacity: true) }
            return
        }
        streamingBytes.removeAll(keepingCapacity: true)
        streamingTranscript = streamingAssembler.append(decoded)
        guard !streamingTranscript.isEmpty else { return }
        state.partial(streamingTranscript, token: token)
        transcript = state.transcript
        for stable in streamingDetector.observeSteps(streamingTranscript) {
            onStableClause?(stable.sourceText)
        }
    }

    private func startStreamingMeter() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw CocoaError(.featureUnsupported) }
        let meter = StreamingAudioLevel()
        input.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            block: Self.streamingMeterTap(meter: meter)
        )
        engine.prepare()
        try engine.start()
        streamMeterEngine = engine
        streamMeter = meter
        streamLevelDB = -160
    }

    private func stopStreamingMeter() {
        guard let engine = streamMeterEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        streamMeterEngine = nil
        streamMeter = nil
    }

    // AVAudioEngine calls this on its real-time service queue. The callback
    // publishes only a number to a thread-safe snapshot; it never captures the
    // MainActor-isolated controller or schedules actor work from the audio
    // thread.
    private nonisolated static func streamingMeterTap(meter: StreamingAudioLevel) -> AVAudioNodeTapBlock {
        { buffer, _ in
            meter.publish(inputLevelDB(buffer))
        }
    }

    private nonisolated static func inputLevelDB(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return -160 }
        let samples = channels[0]
        var energy = 0.0
        for index in 0..<Int(buffer.frameLength) {
            let value = Double(samples[index])
            energy += value * value
        }
        let rms = sqrt(energy / Double(buffer.frameLength))
        return rms > 0 ? max(-160, 20 * log10(rms)) : -160
    }

    private func monitorStreamingSilence(token: UUID) async {
        while !Task.isCancelled, token == state.generation, state.phase == .listening {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, token == state.generation, state.phase == .listening else {
                return
            }
            let levelDB = streamMeter?.load() ?? -160
            streamLevelDB = levelDB
            audioLevel = max(0, min(1, (levelDB + 60) / 60))
            if silenceDetector?.shouldFinish(now: Date(), levelDB: streamLevelDB) == true {
                release()
                return
            }
        }
    }

    private func monitorSilence(token: UUID) async {
        while !Task.isCancelled, token == state.generation, state.phase == .listening {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, token == state.generation, state.phase == .listening else { return }
            recorder?.updateMeters()
            let now = Date()
            let level = recorder?.averagePower(forChannel: 0) ?? -160
            audioLevel = max(0, min(1, (Double(level) + 60) / 60))
            if silenceDetector?.shouldFinish(now: now, levelDB: Double(level)) == true {
                release()
                return
            }
        }
    }

    private func monitorPartials(token: UUID, audioURL: URL) async {
        var detector = StableTranscriptDetector()
        while !Task.isCancelled, token == state.generation, state.phase == .listening {
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled, token == state.generation, state.phase == .listening else { return }
            guard let executable = HelperConfiguration.sttExecutable else { continue }
            let model = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Kio/models/stt/ggml-tiny.en.bin")
            guard FileManager.default.fileExists(atPath: audioURL.path),
                  FileManager.default.fileExists(atPath: model.path) else { continue }
            guard let candidate = await partialTranscription(executable: executable, model: model, audioURL: audioURL) else { continue }
            let stableSteps = detector.observeSteps(candidate)
            guard !stableSteps.isEmpty else { continue }
            await MainActor.run { [weak self] in
                guard let self, self.state.generation == token, self.state.phase == .listening else { return }
                self.state.partial(candidate, token: token)
                self.transcript = candidate
                for stable in stableSteps { self.onStableClause?(stable.sourceText) }
            }
        }
    }

    private func partialTranscription(executable: URL, model: URL, audioURL: URL) async -> String? {
        await Task.detached {
            let child = Process(); let output = Pipe()
            child.executableURL = executable
            child.arguments = ["-m", model.path, "-f", audioURL.path, "-l", "en", "-nt", "-np"]
            child.standardOutput = output; child.standardError = FileHandle.nullDevice
            do { try child.run() } catch { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            child.terminate(); child.waitUntilExit()
            guard child.terminationStatus == 0, data.count <= 16384 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
