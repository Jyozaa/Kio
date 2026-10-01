import AVFoundation
import AppKit
import KioCore
import KioModel
import KioUI
@preconcurrency import Speech
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

private final class CueAudioBufferPacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

private final class CueAudioTapContext: @unchecked Sendable {
    private let appendAudio: @Sendable (AVAudioPCMBuffer) -> Void
    private let onPower: @MainActor (Float) -> Void
    private let lock = NSLock()
    private var lastPowerUpdate = 0.0

    init(appendAudio: @escaping @Sendable (AVAudioPCMBuffer) -> Void, onPower: @escaping @MainActor (Float) -> Void) {
        self.appendAudio = appendAudio
        self.onPower = onPower
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        appendAudio(buffer)
        guard let channel = buffer.floatChannelData?.pointee else { return }
        let count = Int(buffer.frameLength)
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
}

private func cueAudioTapBlock(context: CueAudioTapContext) -> AVAudioNodeTapBlock {
    { buffer, _ in context.append(buffer) }
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
    func append(_ buffer: AVAudioPCMBuffer)
    func stop()
}

@MainActor
private final class LegacyCueSpeechBackend: CueSpeechBackend {
    let name = "Speech Recognition"
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?

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

    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
    func stop() { request.endAudio(); task?.cancel(); task = nil }
}

@available(macOS 26.0, *)
@MainActor
private final class ModernCueSpeechBackend: CueSpeechBackend {
    let name = "SpeechAnalyzer"
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?

    init(transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer) {
        self.transcriber = transcriber
        self.analyzer = analyzer
    }

    static func prepared(locale: Locale, format: AVAudioFormat) async throws -> ModernCueSpeechBackend {
        guard SpeechTranscriber.isAvailable,
              await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            throw CueFailure.unavailable("SpeechAnalyzer is unavailable for this language.")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        return ModernCueSpeechBackend(transcriber: transcriber, analyzer: analyzer)
    }

    func start(onTranscript: @escaping (String, Float, Int) -> Void, generation: Int) {
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        resultTask = Task { @MainActor [transcriber] in
            do {
                for try await result in transcriber.results {
                    onTranscript(String(result.text.characters), 1, generation)
                }
            } catch { }
        }
        analysisTask = Task { [analyzer] in
            do { try await analyzer.start(inputSequence: inputs) }
            catch { }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) { continuation?.yield(AnalyzerInput(buffer: buffer)) }
    func stop() {
        continuation?.finish()
        continuation = nil
        resultTask?.cancel()
        resultTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        Task { await analyzer.cancelAndFinishNow() }
    }
}

@MainActor
private final class CueSpeechRecognizer: ObservableObject {
    var onTranscript: ((String, Float, Int) -> Void)?
    var onPower: ((Float) -> Void)?
    private let engine = AVAudioEngine()
    private var backend: (any CueSpeechBackend)?
    private var audioContinuation: AsyncStream<CueAudioBufferPacket>.Continuation?
    private var audioConsumerTask: Task<Void, Never>?
    private var warmedLocaleIdentifier: String?
    private var warmedSampleRate: Double?
    private var warmedChannelCount: AVAudioChannelCount?
    private var warmedLegacyRecognizer: SFSpeechRecognizer?
    private var warmedBackend: (any CueSpeechBackend)?

    func preheat(locale: Locale) {
        guard warmedLocaleIdentifier != locale.identifier else { return }
        warmedLocaleIdentifier = locale.identifier
        warmedLegacyRecognizer = SFSpeechRecognizer(locale: locale)
        guard #available(macOS 26.0, *) else { return }
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let format = inputFormat.sampleRate > 0
            ? inputFormat
            : AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        warmedSampleRate = format.sampleRate
        warmedChannelCount = format.channelCount
        let localeIdentifier = locale.identifier
        Task { [weak self] in
            guard let self else { return }
            let backend = try? await ModernCueSpeechBackend.prepared(locale: locale, format: format)
            guard self.warmedLocaleIdentifier == localeIdentifier else { return }
            self.warmedBackend = backend
        }
    }

    func start(locale: Locale, hints: [String], generation: Int, recognizeWords: Bool) async throws {
        let micAllowed = await requestCueMicrophonePermission()
        guard micAllowed else { throw CueFailure.permission("Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone.") }
        stop()
        if recognizeWords {
            let speechStatus = await requestCueSpeechAuthorization()
            guard speechStatus == .authorized else { throw CueFailure.permission("Speech Recognition access is off. Enable Kio in System Settings → Privacy & Security → Speech Recognition. Classic mode remains available.") }
        }
        let selectedRecognizer = recognizeWords
            ? (warmedLocaleIdentifier == locale.identifier ? warmedLegacyRecognizer : SFSpeechRecognizer(locale: locale))
            : nil
        if recognizeWords && selectedRecognizer == nil { throw CueFailure.unavailable("Speech recognition is unavailable for this language right now.") }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        var chosenBackend: (any CueSpeechBackend)?
        if recognizeWords {
            if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
                chosenBackend = warmedLocaleIdentifier == locale.identifier
                    && warmedSampleRate == format.sampleRate && warmedChannelCount == format.channelCount
                    ? warmedBackend : nil
                if chosenBackend == nil { chosenBackend = try? await ModernCueSpeechBackend.prepared(locale: locale, format: format) }
            }
            if chosenBackend == nil, let selectedRecognizer, selectedRecognizer.isAvailable {
                chosenBackend = LegacyCueSpeechBackend(recognizer: selectedRecognizer, hints: hints, generation: generation) { [weak self] text, confidence, generation in
                    self?.onTranscript?(text, confidence, generation)
                }
            }
            guard let chosenBackend else { throw CueFailure.unavailable("Speech recognition is unavailable for this language right now.") }
            if #available(macOS 26.0, *), let modern = chosenBackend as? ModernCueSpeechBackend {
                modern.start(onTranscript: { [weak self] text, confidence, generation in
                    self?.onTranscript?(text, confidence, generation)
                }, generation: generation)
            }
        }
        backend = chosenBackend
        let (audioStream, audioContinuation) = AsyncStream<CueAudioBufferPacket>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.audioContinuation = audioContinuation
        self.audioConsumerTask = Task { @MainActor [weak self] in
            for await packet in audioStream {
                guard !Task.isCancelled else { return }
                self?.backend?.append(packet.buffer)
            }
        }
        let audioContext = CueAudioTapContext(appendAudio: { buffer in
            audioContinuation.yield(CueAudioBufferPacket(buffer))
        }) { [weak self] power in
            self?.onPower?(power)
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format,
                         block: cueAudioTapBlock(context: audioContext))
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        if engine.inputNode.numberOfInputs > 0 { engine.inputNode.removeTap(onBus: 0) }
        audioContinuation?.finish()
        audioContinuation = nil
        audioConsumerTask?.cancel()
        audioConsumerTask = nil
        backend?.stop()
        backend = nil
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
        .onDisappear { speech.stop() }
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
                Button("Start") { begin() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: AgentID.cue.colorHex))
                    .controlSize(.small)
                    .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        alignment = CueTextAlignment(script: script)
        readPosition = 0
        complete = false
        paused = false
        errorMessage = nil
        guard !alignment.tokens.isEmpty else { errorMessage = "Add some words to the script first."; return }
        classicClock = CueClassicClock()
        if mode == .classic { isActive = true; lastTick = .now; return }
        Task {
            do {
                speech.onTranscript = { text, confidence, generation in
                    guard isActive, mode != .classic, !paused else { return }
                    let policy: CueTrackingPolicy = mode == .wordTracking ? .accurate : .responsive
                    let value = alignment.consume(text, confidence: confidence, generation: generation, policy: policy)
                    readPosition = min(max(0, value), max(0, alignment.tokens.count - 1))
                    if alignment.isFinished { complete = true; speech.stop() }
                }
                speech.onPower = { power in
                    _ = voiceState.update(power: power)
                }
                try await speech.start(locale: activeLocale, hints: alignment.upcomingContextWords,
                                       generation: alignment.generation, recognizeWords: mode != .classic)
                isActive = true
                lastTick = .now
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func advanceClassic() {
        let now = Date.now
        let delta = now.timeIntervalSince(lastTick)
        lastTick = now
        guard !paused else { return }
        let next = Int(classicClock.advance(elapsed: delta, wordsPerMinute: speed,
                                            totalWords: alignment.tokens.count, paused: false))
        if next != readPosition { readPosition = next; if next >= alignment.tokens.count { complete = true } }
    }

    private func jump(to index: Int) {
        guard isActive else { return }
        _ = alignment.jump(to: index)
        readPosition = index
        if mode != .classic {
            Task {
                do {
                    try await speech.start(locale: activeLocale, hints: alignment.upcomingContextWords,
                                           generation: alignment.generation, recognizeWords: true)
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private func restart() {
        speech.stop()
        alignment = CueTextAlignment(script: script)
        readPosition = 0
        complete = false
        paused = false
        classicClock = CueClassicClock()
        if mode != .classic {
            isActive = false
            begin()
        }
        lastTick = .now
    }

    private func exitCue() { speech.stop(); isActive = false; complete = false; onDone() }

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
