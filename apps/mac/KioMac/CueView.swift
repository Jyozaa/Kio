import AVFoundation
import AppKit
import KioCore
import KioModel
import KioUI
@preconcurrency import Speech
import os
import SwiftUI

// These permission callbacks can arrive on a background queue. Keep the continuation
// bridge nonisolated so resuming it never performs a MainActor queue assertion there.
private func requestCueMicrophonePermission() async -> Bool {
    await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .audio) { allowed in
            continuation.resume(returning: allowed)
        }
    }
}

private func requestCueSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { status in
            continuation.resume(returning: status)
        }
    }
}

private let cueLogger = Logger(subsystem: "app.kio.mac", category: "Cue")

private protocol CueAudioInputSink: Sendable {
    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime)
}

private final class CueLegacyAudioInputSink: CueAudioInputSink, @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest

    init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        request.append(buffer)
    }
}

@available(macOS 26.0, *)
private final class CueAnalyzerInputConverterBox: @unchecked Sendable {
    private let lock = NSLock()
    private let conversion: (AVAudioPCMBuffer, AVAudioTime) throws -> [AnalyzerInput]

    init(captureFormat: AVAudioFormat, analyzerFormat: AVAudioFormat) throws {
        if #available(macOS 27.0, *) {
            let converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
            conversion = { buffer, time in try converter.convert(buffer, at: time) }
        } else {
            guard let converter = AVAudioConverter(from: captureFormat, to: analyzerFormat) else {
                throw CueFailure.unavailable("Cue couldn't create a safe audio converter for SpeechAnalyzer.")
            }
            conversion = { buffer, time in
                let ratio = analyzerFormat.sampleRate / captureFormat.sampleRate
                let capacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * ratio) + 128))
                guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
                    throw CueFailure.unavailable("Cue couldn't allocate an analyzer audio buffer.")
                }
                var suppliedInput = false
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                    guard !suppliedInput else {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    suppliedInput = true
                    inputStatus.pointee = .haveData
                    return buffer
                }
                if status == .error {
                    throw conversionError ?? CueFailure.unavailable("Cue couldn't convert microphone audio for SpeechAnalyzer.")
                }
                guard output.frameLength > 0 else { return [] }
                return [AnalyzerInput(buffer: output, bufferStartTime: Self.startTime(for: time))]
            }
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) throws -> [AnalyzerInput] {
        lock.lock()
        defer { lock.unlock() }
        return try conversion(buffer, time)
    }

    private static func startTime(for time: AVAudioTime) -> CMTime? {
        guard time.isSampleTimeValid, time.sampleRate.isFinite, time.sampleRate > 0,
              time.sampleTime >= 0, time.sampleRate <= Double(Int32.max) else { return nil }
        let timescale = Int32(time.sampleRate.rounded())
        guard timescale > 0 else { return nil }
        return CMTime(value: time.sampleTime, timescale: timescale)
    }
}

@available(macOS 26.0, *)
private final class CueAnalyzerAudioInputSink: CueAudioInputSink, @unchecked Sendable {
    private let converter: CueAnalyzerInputConverterBox
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let lock = NSLock()
    private var didLogConversionFailure = false

    init(converter: CueAnalyzerInputConverterBox, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.converter = converter
        self.continuation = continuation
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        do {
            for input in try converter.convert(buffer, at: time) { continuation.yield(input) }
        } catch {
            lock.lock()
            let shouldLog = !didLogConversionFailure
            didLogConversionFailure = true
            lock.unlock()
            if shouldLog { cueLogger.error("Cue analyzer audio conversion failed: \(String(reflecting: type(of: error)), privacy: .public).") }
        }
    }
}

private final class CueAudioTapContext: @unchecked Sendable {
    private let audioSink: any CueAudioInputSink
    private let captureConverter: AVAudioConverter?
    private let captureFormat: AVAudioFormat
    private let onPower: @MainActor (Float) -> Void
    private let lock = NSLock()
    private var lastPowerUpdate = 0.0
    private var didLogCaptureFailure = false

    init(audioSink: any CueAudioInputSink, captureConverter: AVAudioConverter?, captureFormat: AVAudioFormat,
         onPower: @escaping @MainActor (Float) -> Void) {
        self.audioSink = audioSink
        self.captureConverter = captureConverter
        self.captureFormat = captureFormat
        self.onPower = onPower
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let capturedBuffer: AVAudioPCMBuffer
        if let captureConverter {
            if let converted = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: buffer.frameLength) {
                do {
                    try captureConverter.convert(to: converted, from: buffer)
                    capturedBuffer = converted
                } catch {
                    logCaptureFailure(error)
                    capturedBuffer = buffer
                }
            } else {
                logCaptureFailure(CueFailure.unavailable("Cue couldn't allocate a mono microphone buffer."))
                capturedBuffer = buffer
            }
        } else {
            capturedBuffer = buffer
        }
        audioSink.append(capturedBuffer, at: time)
        guard let channel = capturedBuffer.floatChannelData?.pointee else { return }
        let count = Int(capturedBuffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for index in 0..<count { sum += channel[index] * channel[index] }
        let power = sqrt(sum / Float(count))
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let shouldPublish = now - lastPowerUpdate >= 1.0 / 25.0
        if shouldPublish { lastPowerUpdate = now }
        lock.unlock()
        guard shouldPublish else { return }
        Task { @MainActor [onPower] in onPower(power) }
    }

    private func logCaptureFailure(_ error: Error) {
        lock.lock()
        let shouldLog = !didLogCaptureFailure
        didLogCaptureFailure = true
        lock.unlock()
        if shouldLog { cueLogger.error("Cue microphone capture conversion failed; using the device buffer: \(String(reflecting: type(of: error)), privacy: .public).") }
    }
}

private func cueAudioTapBlock(context: CueAudioTapContext) -> AVAudioNodeTapBlock {
    { buffer, time in context.append(buffer, at: time) }
}

private enum CueMode: String, CaseIterable, Identifiable {
    case wordTracking = "Word Tracking"
    case classic = "Classic"
    case followMyVoice = "Follow My Voice"

    init?(rawValue: String) {
        switch rawValue {
        case "Classic": self = .classic
        case "Follow My Voice", "Voice-Paced": self = .followMyVoice
        case "Word Tracking": self = .wordTracking
        default: return nil
        }
    }
    var id: String { rawValue }
}

private enum CueTextSize: String, CaseIterable, Identifiable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"
    case extraLarge = "Extra Large"

    var id: String { rawValue }
    var points: CGFloat {
        switch self {
        case .small: 17
        case .medium: 21
        case .large: 25
        case .extraLarge: 29
        }
    }
}

@MainActor
private protocol CueSpeechBackend: AnyObject {
    var name: String { get }
    func start(onTranscript: @escaping (String, Float, Int) -> Void, generation: Int,
               onFailure: @escaping @MainActor (Error) -> Void) throws -> any CueAudioInputSink
    func stop()
}

@MainActor
private final class LegacyCueSpeechBackend: CueSpeechBackend {
    let name = "Speech Recognition"
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?
    private var didStart = false

    init(recognizer: SFSpeechRecognizer, hints: [String], generation: Int,
         onTranscript: @escaping (String, Float, Int) -> Void) {
        request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = Array(hints.prefix(32))
        task = recognizer.recognitionTask(with: request) { result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            let confidence = result.bestTranscription.segments.last?.confidence ?? 0
            Task { @MainActor in onTranscript(text, confidence, generation) }
        }
    }

    func start(onTranscript: @escaping (String, Float, Int) -> Void, generation: Int,
               onFailure: @escaping @MainActor (Error) -> Void) throws -> any CueAudioInputSink {
        guard !didStart else { throw CueFailure.unavailable("Cue speech recognition has already started.") }
        didStart = true
        return CueLegacyAudioInputSink(request: request)
    }
    func stop() { request.endAudio(); task?.cancel(); task = nil }
}

@available(macOS 26.0, *)
@MainActor
private final class ModernCueSpeechBackend: CueSpeechBackend {
    let name = "SpeechAnalyzer"
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let inputConverter: CueAnalyzerInputConverterBox
    private enum State: Equatable { case prepared, running, stopping, stopped }
    private var state: State = .prepared
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?

    init(transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, inputConverter: CueAnalyzerInputConverterBox) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.inputConverter = inputConverter
    }

    static func prepared(locale: Locale, captureFormat: AVAudioFormat) async throws -> ModernCueSpeechBackend {
        guard SpeechTranscriber.isAvailable,
              await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            throw CueFailure.unavailable("SpeechAnalyzer is unavailable for this language.")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: captureFormat
        ) else { throw CueFailure.unavailable("SpeechAnalyzer has no compatible audio format for this language.") }
        let analyzerDescriptor = CueAudioFormatDescriptor(sampleRate: analyzerFormat.sampleRate,
                                                           channelCount: analyzerFormat.channelCount)
        guard CueAudioFormatPolicy.analyzerFormat(preferred: analyzerDescriptor) != nil else {
            throw CueFailure.unavailable("SpeechAnalyzer returned an invalid audio format.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        let inputConverter = try CueAnalyzerInputConverterBox(captureFormat: captureFormat, analyzerFormat: analyzerFormat)
        cueLogger.info("SpeechAnalyzer prepared: capture=\(captureFormat.sampleRate, privacy: .public) Hz/\(captureFormat.channelCount, privacy: .public) ch, analyzer=\(analyzerFormat.sampleRate, privacy: .public) Hz/\(analyzerFormat.channelCount, privacy: .public) ch.")
        return ModernCueSpeechBackend(transcriber: transcriber, analyzer: analyzer, inputConverter: inputConverter)
    }

    func start(onTranscript: @escaping (String, Float, Int) -> Void, generation: Int,
               onFailure: @escaping @MainActor (Error) -> Void) throws -> any CueAudioInputSink {
        guard state == .prepared else { throw CueFailure.unavailable("Cue's SpeechAnalyzer input sequence cannot be restarted.") }
        state = .running
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.continuation = continuation
        resultTask = Task { @MainActor [transcriber] in
            do {
                for try await result in transcriber.results {
                    onTranscript(String(result.text.characters), 1, generation)
                }
            } catch { }
        }
        analysisTask = Task { @MainActor [analyzer, onFailure] in
            do { try await analyzer.start(inputSequence: inputs) }
            catch {
                cueLogger.error("SpeechAnalyzer failed during start: \(String(reflecting: type(of: error)), privacy: .public).")
                onFailure(error)
            }
        }
        return CueAnalyzerAudioInputSink(converter: inputConverter, continuation: continuation)
    }

    func stop() {
        guard state != .stopped, state != .stopping else { return }
        state = .stopping
        continuation?.finish()
        continuation = nil
        resultTask?.cancel()
        resultTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
        state = .stopped
    }

}

@MainActor
private final class CueSpeechRecognizer: ObservableObject {
    var onTranscript: ((String, Float, Int) -> Void)?
    var onPower: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    private struct LegacyFallbackConfiguration {
        let recognizer: SFSpeechRecognizer
        let hints: [String]
        let generation: Int
        let captureConverter: AVAudioConverter?
        let captureFormat: AVAudioFormat
    }
    private let engine = AVAudioEngine()
    private var backend: (any CueSpeechBackend)?
    private var audioTapContext: CueAudioTapContext?
    private var tapInstalled = false
    private var lifecycle = CueAudioSessionLifecycle()
    private var warmedLocaleIdentifier: String?
    private var warmedLegacyRecognizer: SFSpeechRecognizer?
    private var legacyFallbackConfiguration: LegacyFallbackConfiguration?

    func preheat(locale: Locale) {
        guard warmedLocaleIdentifier != locale.identifier else { return }
        warmedLocaleIdentifier = locale.identifier
        warmedLegacyRecognizer = SFSpeechRecognizer(locale: locale)
        guard #available(macOS 26.0, *) else { return }
        Task {
            let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
            cueLogger.info("Cue locale preheat completed; SpeechAnalyzer locale supported=\(supported, privacy: .public).")
        }
    }

    func start(locale: Locale, hints: [String], generation: Int, recognizeWords: Bool) async throws {
        stop()
        guard let attempt = lifecycle.beginStart() else {
            throw CueFailure.unavailable("Cue audio is already starting.")
        }
        do {
            let micAllowed = await requestCueMicrophonePermission()
            try Task.checkCancellation()
            guard lifecycle.isCurrent(attempt) else { throw CancellationError() }
            guard micAllowed else { throw CueFailure.permission("Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone.") }

            if recognizeWords {
                let speechStatus = await requestCueSpeechAuthorization()
                try Task.checkCancellation()
                guard lifecycle.isCurrent(attempt) else { throw CancellationError() }
                guard speechStatus == .authorized else {
                    throw CueFailure.permission("Speech Recognition access is off. Enable Kio in System Settings → Privacy & Security → Speech Recognition. Classic mode remains available.")
                }
            }

            let input = engine.inputNode
            let hardwareFormat = input.outputFormat(forBus: 0)
            let hardwareDescriptor = CueAudioFormatDescriptor(sampleRate: hardwareFormat.sampleRate,
                                                               channelCount: hardwareFormat.channelCount)
            guard hardwareDescriptor.isValid else {
                throw CueFailure.unavailable("Cue couldn't use the microphone's current audio format.")
            }
            let requestedCaptureFormat = cueCaptureFormat(for: hardwareFormat)
            let captureConverter: AVAudioConverter?
            let captureFormat: AVAudioFormat
            if let requestedCaptureFormat,
               let converter = AVAudioConverter(from: hardwareFormat, to: requestedCaptureFormat) {
                captureConverter = converter
                captureFormat = requestedCaptureFormat
            } else {
                // Keep the actual device format if mono conversion isn't supported; Speech's converter
                // can still downmix it, and the legacy recognizer receives the unmodified device buffer.
                captureConverter = nil
                captureFormat = hardwareFormat
                cueLogger.error("Cue couldn't create same-rate mono capture conversion; using the validated hardware format.")
            }
            let captureDescriptor = CueAudioFormatDescriptor(sampleRate: captureFormat.sampleRate,
                                                               channelCount: captureFormat.channelCount)
            guard CueAudioFormatPolicy.captureFormat(for: hardwareDescriptor) != nil,
                  captureDescriptor.isValid else {
                throw CueFailure.unavailable("Cue couldn't create a safe microphone capture format.")
            }

            let selectedRecognizer = warmedLocaleIdentifier == locale.identifier
                ? warmedLegacyRecognizer : SFSpeechRecognizer(locale: locale)
            var chosenBackend: (any CueSpeechBackend)?
            if recognizeWords {
                if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
                    do {
                        chosenBackend = try await ModernCueSpeechBackend.prepared(locale: locale, captureFormat: captureFormat)
                    } catch {
                        cueLogger.warning("SpeechAnalyzer setup failed; trying Speech Recognition fallback (\(String(reflecting: type(of: error)), privacy: .public)).")
                    }
                    guard lifecycle.isCurrent(attempt) else { throw CancellationError() }
                }
                if chosenBackend == nil, let selectedRecognizer, selectedRecognizer.isAvailable {
                    chosenBackend = LegacyCueSpeechBackend(recognizer: selectedRecognizer, hints: hints,
                                                           generation: generation) { [weak self] text, confidence, generation in
                        self?.onTranscript?(text, confidence, generation)
                    }
                }
                guard let chosenBackend else {
                    throw CueFailure.unavailable("Speech recognition is unavailable for this language right now.")
                }
                if #available(macOS 26.0, *), chosenBackend is ModernCueSpeechBackend,
                   let selectedRecognizer, selectedRecognizer.isAvailable {
                    legacyFallbackConfiguration = LegacyFallbackConfiguration(recognizer: selectedRecognizer,
                        hints: hints, generation: generation, captureConverter: captureConverter,
                        captureFormat: captureFormat)
                } else {
                    legacyFallbackConfiguration = nil
                }
                let sink = try chosenBackend.start(onTranscript: { [weak self] text, confidence, generation in
                    self?.onTranscript?(text, confidence, generation)
                }, generation: generation, onFailure: { [weak self] error in
                    self?.fallbackFromModern(error, attempt: attempt)
                })
                backend = chosenBackend
                cueLogger.info("Cue selected backend: \(chosenBackend.name, privacy: .public); tap installed=false.")
                let audioContext = CueAudioTapContext(audioSink: sink, captureConverter: captureConverter,
                                                      captureFormat: captureFormat) { [weak self] power in
                    self?.onPower?(power)
                }
                guard !tapInstalled else { throw CueFailure.unavailable("Cue already has an active microphone tap.") }
                input.installTap(onBus: 0, bufferSize: 1_024, format: nil,
                                 block: cueAudioTapBlock(context: audioContext))
                tapInstalled = true
                audioTapContext = audioContext
                guard lifecycle.installTap(for: attempt) else {
                    input.removeTap(onBus: 0)
                    tapInstalled = false
                    throw CueFailure.unavailable("Cue couldn't safely attach its microphone tap.")
                }
                cueLogger.info("Cue microphone: hardware=\(hardwareFormat.sampleRate, privacy: .public) Hz/\(hardwareFormat.channelCount, privacy: .public) ch, capture=\(captureFormat.sampleRate, privacy: .public) Hz/\(captureFormat.channelCount, privacy: .public) ch, tap installed=true.")
            }

            engine.prepare()
            try engine.start()
            guard lifecycle.didStart(attempt) else {
                throw CueFailure.unavailable("Cue audio startup was interrupted before the engine started.")
            }
            cueLogger.info("Cue audio session started; backend=\(self.backend?.name ?? "Classic", privacy: .public).")
        } catch {
            if lifecycle.isCurrent(attempt) {
                tearDownRuntime(for: attempt)
                lifecycle.failStart(attempt)
            }
            if !(error is CancellationError) {
                cueLogger.error("Cue startup failed: \(String(reflecting: type(of: error)), privacy: .public); tap installed=\(self.tapInstalled, privacy: .public).")
            }
            throw error
        }
    }

    func stop() {
        let attempt = lifecycle.generation
        tearDownRuntime(for: attempt)
        lifecycle.stop()
        cueLogger.info("Cue audio session stopped; tap installed=\(self.tapInstalled, privacy: .public).")
    }

    private func tearDownRuntime(for attempt: Int) {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            lifecycle.removeTap(attempt)
        }
        audioTapContext = nil
        backend?.stop()
        backend = nil
        legacyFallbackConfiguration = nil
    }

    private func cueCaptureFormat(for hardwareFormat: AVAudioFormat) -> AVAudioFormat? {
        let descriptor = CueAudioFormatDescriptor(sampleRate: hardwareFormat.sampleRate,
                                                  channelCount: hardwareFormat.channelCount)
        guard let capture = CueAudioFormatPolicy.captureFormat(for: descriptor) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: capture.sampleRate,
                             channels: capture.channelCount, interleaved: false)
    }

    private func fallbackFromModern(_ error: Error, attempt: Int) {
        guard #available(macOS 26.0, *), lifecycle.isCurrent(attempt), backend is ModernCueSpeechBackend,
              lifecycle.beginFallback(attempt) else { return }
        cueLogger.warning("SpeechAnalyzer failed after startup; switching to Speech Recognition fallback (\(String(reflecting: type(of: error)), privacy: .public)).")
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            lifecycle.removeTap(attempt)
        }
        audioTapContext = nil
        backend?.stop()
        backend = nil

        guard let configuration = legacyFallbackConfiguration,
              configuration.recognizer.isAvailable else {
            failSpeechFallback(for: attempt)
            return
        }
        do {
            let legacy = LegacyCueSpeechBackend(recognizer: configuration.recognizer,
                hints: configuration.hints, generation: configuration.generation) { [weak self] text, confidence, generation in
                    self?.onTranscript?(text, confidence, generation)
                }
            let sink = try legacy.start(onTranscript: { [weak self] text, confidence, generation in
                self?.onTranscript?(text, confidence, generation)
            }, generation: configuration.generation, onFailure: { _ in })
            let context = CueAudioTapContext(audioSink: sink,
                captureConverter: configuration.captureConverter, captureFormat: configuration.captureFormat) { [weak self] power in
                    self?.onPower?(power)
                }
            engine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: nil,
                                        block: cueAudioTapBlock(context: context))
            tapInstalled = true
            audioTapContext = context
            guard lifecycle.installTap(for: attempt) else {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
                throw CueFailure.unavailable("Cue couldn't safely attach its fallback microphone tap.")
            }
            backend = legacy
            engine.prepare()
            try engine.start()
            guard lifecycle.didStart(attempt) else {
                throw CueFailure.unavailable("Cue's fallback audio startup was interrupted.")
            }
            legacyFallbackConfiguration = nil
            cueLogger.info("Cue fallback started: backend=Speech Recognition, tap installed=\(self.tapInstalled, privacy: .public).")
        } catch {
            tearDownRuntime(for: attempt)
            lifecycle.failStart(attempt)
            onFailure?("Cue couldn't start SpeechAnalyzer or Speech Recognition. Try Classic mode or select another language.")
        }
    }

    private func failSpeechFallback(for attempt: Int) {
        tearDownRuntime(for: attempt)
        lifecycle.failStart(attempt)
        onFailure?("Cue couldn't start SpeechAnalyzer or Speech Recognition. Try Classic mode or select another language.")
    }
}

private enum CueFailure: LocalizedError {
    case permission(String), unavailable(String)
    var errorDescription: String? {
        switch self { case .permission(let value), .unavailable(let value): value }
    }
}

struct CueSurfaceView: View {
    var onActiveChange: (Bool) -> Void = { _ in }
    var onDone: () -> Void = {}
    @Binding var initialText: String
    @State private var script = ""
    @State private var mode: CueMode = .wordTracking
    @State private var textSize: CueTextSize = .medium
    @State private var speed: Double = 150
    @State private var languageIdentifier = "system"
    @State private var isActive = false
    @State private var isStarting = false
    @State private var paused = false
    @State private var complete = false
    @State private var errorMessage: String?
    @State private var readPosition = 0
    @State private var alignment = CueTextAlignment(script: "")
    @State private var voiceState = CueVoiceActivityState()
    @State private var classicClock = CueClassicClock()
    @State private var lastTick = Date.now
    @State private var transcriptGeneration = 0
    @State private var controlsVisible = false
    @State private var controlsHovered = false
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var startTask: Task<Void, Never>?
    @State private var completionTask: Task<Void, Never>?
    @State private var startGeneration = 0
    @State private var fileImporter = false
    @StateObject private var speech = CueSpeechRecognizer()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isActive { teleprompter }
            else { setup }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $fileImporter, allowedContentTypes: [.plainText, .text], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                do { script = try String(contentsOf: url, encoding: .utf8) }
                catch { errorMessage = "Kio couldn't read that text file as UTF-8." }
            }
        }
        .onExitCommand { exitCue() }
        .onDisappear {
            startGeneration &+= 1
            startTask?.cancel()
            completionTask?.cancel()
            speech.stop()
        }
        .onChange(of: isActive) { _, value in onActiveChange(value) }
        .onAppear {
            if !initialText.isEmpty { script = initialText; initialText = "" }
            speech.preheat(locale: activeLocale)
        }
        .onChange(of: mode) { _, _ in speech.preheat(locale: activeLocale) }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                AgentBlob(.cue, mood: .curious, size: 25)
                Text("Cue").font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                Button { fileImporter = true } label: { Image(systemName: "doc.badge.plus") }
                    .cueIconButton("Open a text file")
                Button { if let clipboard = NSPasteboard.general.string(forType: .string) { script = clipboard } } label: { Image(systemName: "doc.on.clipboard") }
                    .cueIconButton("Paste from clipboard")
                Button { exitCue() } label: { Image(systemName: "xmark") }
                    .cueIconButton("Close Cue")
            }
            TextEditor(text: $script)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(Color.white.opacity(0.085), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    if script.isEmpty {
                        Text("Paste or type your speaking script")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.44))
                            .padding(.leading, 12)
                            .padding(.top, 11)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48, maxHeight: .infinity)

            HStack(spacing: 6) {
                modeMenu
                textSizeMenu
                if mode == .wordTracking { languageMenu }
                Spacer(minLength: 0)
            }
            HStack {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 3)
                Button(isStarting ? "Starting…" : "Start") { begin() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: AgentID.cue.colorHex))
                    .controlSize(.small)
                    .disabled(isStarting || script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let errorMessage {
                HStack(spacing: 4) {
                    if errorMessage.localizedCaseInsensitiveContains("access") || errorMessage.localizedCaseInsensitiveContains("permission") {
                        Button("Microphone Settings") { openPrivacyPane("Privacy_Microphone") }
                            .font(.system(size: 8)).buttonStyle(.plain)
                        if mode == .wordTracking {
                            Button("Speech Settings") { openPrivacyPane("Privacy_SpeechRecognition") }
                                .font(.system(size: 8)).buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 2)
    }

    private var teleprompter: some View {
        VStack(spacing: 0) {
            if complete {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: AgentID.cue.colorHex))
                Text("Script complete").font(.system(size: 12, weight: .semibold))
                HStack { Button("Restart") { restart() }; Button("Done") { exitCue() } }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                ScrollViewReader { proxy in
                    ZStack(alignment: .top) {
                        ScrollView {
                            cueText
                                .padding(.vertical, 12)
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: visiblePosition) { _, value in
                            guard alignment.tokens.indices.contains(value) else { return }
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { proxy.scrollTo(value, anchor: .center) }
                        }
                        if controlsVisible {
                            controlsOverlay
                                .padding(.top, 2)
                                .transition(.opacity)
                                .zIndex(2)
                                .onHover { hovering in
                                    controlsHovered = hovering
                                    if !hovering { scheduleControlsHide() }
                                }
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active = phase { revealControls() }
                    }
                }
                statusStrip
            }
        }
        .foregroundStyle(.white.opacity(0.93))
        .padding(.horizontal, 8)
        .task(id: isActive) {
            guard isActive, mode == .classic, !complete else { return }
            while !Task.isCancelled && isActive && !complete && mode == .classic {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                advanceClassic()
            }
        }
        .onKeyPress(.space) {
            guard mode == .classic else { return .ignored }
            paused.toggle(); return .handled
        }
    }

    private var visiblePosition: Int {
        let lead = mode == .followMyVoice && voiceState.isSpeaking && !paused ? 1 : 0
        return min(max(0, readPosition + lead), max(0, alignment.tokens.count - 1))
    }

    private var statusStrip: some View {
        HStack(spacing: 8) {
            CueWaveform(levels: voiceState.waveform.levels, speaking: voiceState.isSpeaking)
                .frame(width: 92, height: 22)
            Text(alignment.recentSpokenWords.isEmpty ? (paused ? "Paused" : mode == .classic ? "Classic" : "Listening…") : "\(alignment.recentSpokenWords)…")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: paused ? "pause.fill" : mode == .classic ? "text.alignleft" : "mic.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(paused || mode == .classic ? .white.opacity(0.42) : Color(hex: AgentID.cue.colorHex))
                .accessibilityLabel(paused ? "Paused" : mode == .classic ? "Classic scrolling" : "Listening")
            Button { exitCue() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Done and close Cue")
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var controlsOverlay: some View {
        HStack(spacing: 7) {
            Button(paused ? "Resume" : "Pause") { paused.toggle(); lastTick = .now }
            Button("Restart") { restart() }
            textSizeMenu
            if mode == .classic {
                Slider(value: $speed, in: 60...260, step: 10).frame(maxWidth: 82).help("Reading speed")
            }
            Spacer(minLength: 0)
            Text("\(min(readPosition, alignment.tokens.count)) / \(alignment.tokens.count)")
                .font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.65))
        }
        .buttonStyle(.bordered).controlSize(.mini)
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func revealControls() {
        controlsHideTask?.cancel()
        controlsVisible = true
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        controlsHideTask?.cancel()
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2_800))
            guard !Task.isCancelled, !controlsHovered else { return }
            withAnimation(.easeOut(duration: 0.18)) { controlsVisible = false }
        }
    }

    private var cueText: some View {
        let ns = script as NSString
        let start = max(0, visiblePosition - 14)
        let end = min(alignment.tokens.count, max(visiblePosition + 24, 32))
        let window = start..<end
        return CueFlowLayout(spacing: 4, lineSpacing: 8) {
            ForEach(Array(window), id: \.self) { index in
                let token = alignment.tokens[index]
                let end = index + 1 < alignment.tokens.count ? alignment.tokens[index + 1].range.location : ns.length
                let range = NSRange(location: token.range.location, length: max(0, end - token.range.location))
                let fragment = range.location <= ns.length && NSMaxRange(range) <= ns.length ? ns.substring(with: range) : token.text
                Text(fragment)
                    .font(.system(size: textSize.points, weight: .regular, design: .rounded))
                    .foregroundStyle(index < visiblePosition ? .white.opacity(0.62) :
                                     index == visiblePosition ? Color(hex: AgentID.cue.colorHex) :
                                     index <= visiblePosition + 8 ? .white.opacity(0.87) : .white.opacity(0.59))
                    .lineSpacing(8)
                    .id(index)
                    .onTapGesture { jump(to: index) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 90, maxHeight: .infinity, alignment: .center)
    }

    private func begin() {
        guard !isStarting else { return }
        alignment = CueTextAlignment(script: script)
        readPosition = 0
        complete = false
        paused = false
        errorMessage = nil
        guard !alignment.tokens.isEmpty else { errorMessage = "Add some words to the script first."; return }
        classicClock = CueClassicClock()
        if mode == .classic { isActive = true; lastTick = .now; return }
        startSpeechSession()
    }

    private func startSpeechSession() {
        guard !isStarting else { return }
        startTask?.cancel()
        startGeneration &+= 1
        let currentGeneration = startGeneration
        isStarting = true
        speech.onFailure = { message in
            errorMessage = message
            isActive = false
            isStarting = false
        }
        startTask = Task { @MainActor in
            do {
                speech.onTranscript = { text, confidence, generation in
                    guard isActive, !complete, mode != .classic, !paused else { return }
                    let policy: CueTrackingPolicy = mode == .wordTracking ? .accurate : .responsive
                    let value = alignment.consume(text, confidence: confidence, generation: generation, policy: policy)
                    readPosition = min(max(0, value), max(0, alignment.tokens.count - 1))
                    if alignment.isFinished { finishScript() }
                }
                speech.onPower = { power in
                    _ = voiceState.update(power: power)
                }
                try await speech.start(locale: activeLocale, hints: alignment.upcomingContextWords,
                                       generation: alignment.generation, recognizeWords: mode != .classic)
                guard !Task.isCancelled, currentGeneration == startGeneration else { speech.stop(); return }
                isActive = true
                lastTick = .now
            } catch is CancellationError {
                // A newer Start/Restart or closing Cue invalidated this request.
            } catch {
                if currentGeneration == startGeneration { errorMessage = error.localizedDescription }
            }
            if currentGeneration == startGeneration { isStarting = false }
        }
    }

    private func advanceClassic() {
        let now = Date.now
        let delta = now.timeIntervalSince(lastTick)
        lastTick = now
        guard !paused else { return }
        let next = Int(classicClock.advance(elapsed: delta, wordsPerMinute: speed,
                                            totalWords: alignment.tokens.count, paused: false))
        if next != readPosition { readPosition = next; if next >= alignment.tokens.count { finishScript() } }
    }

    private func jump(to index: Int) {
        guard isActive else { return }
        _ = alignment.jump(to: index)
        readPosition = index
        if mode != .classic {
            startSpeechSession()
        }
    }

    private func restart() {
        completionTask?.cancel()
        completionTask = nil
        startGeneration &+= 1
        startTask?.cancel()
        isStarting = false
        speech.stop()
        alignment = CueTextAlignment(script: script)
        readPosition = 0
        complete = false
        paused = false
        classicClock = CueClassicClock()
        if mode != .classic {
            errorMessage = nil
            startSpeechSession()
            isActive = true
        } else {
            isActive = true
        }
        lastTick = .now
    }

    private func finishScript() {
        guard !complete else { return }
        complete = true
        speech.stop()
        completionTask?.cancel()
        completionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            exitCue()
        }
    }

    private func exitCue() {
        startGeneration &+= 1
        startTask?.cancel()
        completionTask?.cancel()
        speech.stop()
        isStarting = false
        isActive = false
        complete = false
        onDone()
    }

    private var activeLocale: Locale {
        languageIdentifier == "system" ? .current : Locale(identifier: languageIdentifier)
    }

    private var speechLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted {
            ($0.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                .localizedStandardCompare($1.localizedString(forIdentifier: $1.identifier) ?? $1.identifier) == .orderedAscending
        }
    }

    private var modeMenu: some View {
        Menu {
            ForEach(CueMode.allCases) { option in
                Button(option.rawValue) { mode = option }
            }
        } label: {
            compactMenuLabel(mode.rawValue)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Cue mode: \(mode.rawValue)")
    }

    private var textSizeMenu: some View {
        Menu {
            ForEach(CueTextSize.allCases) { option in
                Button(option.rawValue) { textSize = option }
            }
        } label: {
            compactMenuLabel("Text: \(textSize.rawValue)")
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Text size: \(textSize.rawValue)")
    }

    private var languageMenu: some View {
        Menu {
            Button("System Default") { languageIdentifier = "system" }
            ForEach(speechLocales, id: \.identifier) { locale in
                Button(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) {
                    languageIdentifier = locale.identifier
                }
            }
        } label: {
            Label(languageTitle, systemImage: "globe")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.055), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.09), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .help("Speech recognition language")
        .accessibilityLabel("Speech recognition language: \(languageTitle)")
    }

    private var languageTitle: String {
        guard languageIdentifier != "system" else { return "System" }
        return Locale(identifier: languageIdentifier).localizedString(forIdentifier: languageIdentifier) ?? languageIdentifier
    }

    private func compactMenuLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
        }
        .font(.system(size: 9, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.055), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.09), lineWidth: 1))
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private extension View {
    func cueIconButton(_ title: String) -> some View {
        self
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.76))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .help(title)
    }
}

private struct CueFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 420
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + lineSpacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + lineSpacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct CueWaveform: View {
    let levels: [Float]
    let speaking: Bool

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let gap: CGFloat = 2
            let barWidth = max(1, (size.width - CGFloat(levels.count - 1) * gap) / CGFloat(levels.count))
            let accent = Color(hex: AgentID.cue.colorHex)
            for (index, value) in levels.enumerated() {
                let normalized = value.isFinite ? min(1, max(0, value)) : 0
                let height = max(2, CGFloat(normalized) * size.height)
                let rect = CGRect(x: CGFloat(index) * (barWidth + gap), y: (size.height - height) / 2,
                                  width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(speaking ? accent.opacity(0.92) : .white.opacity(0.27)))
            }
        }
        .accessibilityLabel(speaking ? "Audio waveform, speaking" : "Audio waveform, quiet")
    }
}
