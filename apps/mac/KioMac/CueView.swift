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

private final class CueAudioTapContext: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest?
    private let onPower: @MainActor (Float) -> Void

    init(request: SFSpeechAudioBufferRecognitionRequest?, onPower: @escaping @MainActor (Float) -> Void) {
        self.request = request
        self.onPower = onPower
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
        guard let channel = buffer.floatChannelData?.pointee else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for index in 0..<count { sum += channel[index] * channel[index] }
        let power = sqrt(sum / Float(count))
        Task { @MainActor [onPower] in onPower(power) }
    }
}

private func cueAudioTapBlock(context: CueAudioTapContext) -> AVAudioNodeTapBlock {
    { buffer, _ in context.append(buffer) }
}

private enum CueMode: String, CaseIterable, Identifiable {
    case wordTracking = "Word Tracking"
    case classic = "Classic"
    case voicePaced = "Voice-Paced"
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
private final class CueSpeechRecognizer: ObservableObject {
    var onTranscript: ((String, Float, Int) -> Void)?
    var onPower: ((Float) -> Void)?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    func start(locale: Locale, hints: [String], generation: Int, recognizeWords: Bool) async throws {
        let micAllowed = await requestCueMicrophonePermission()
        guard micAllowed else { throw CueFailure.permission("Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone.") }
        let recognizer: SFSpeechRecognizer?
        if recognizeWords {
            let speechStatus = await requestCueSpeechAuthorization()
            guard speechStatus == .authorized else { throw CueFailure.permission("Speech Recognition access is off. Enable Kio in System Settings → Privacy & Security → Speech Recognition. Classic mode remains available.") }
            guard let selected = SFSpeechRecognizer(locale: locale), selected.isAvailable else { throw CueFailure.unavailable("Speech recognition is unavailable for this language right now.") }
            recognizer = selected
        } else { recognizer = nil }
        self.recognizer = recognizer
        stop()
        let request: SFSpeechAudioBufferRecognitionRequest?
        if recognizeWords {
            let created = SFSpeechAudioBufferRecognitionRequest()
            created.shouldReportPartialResults = true
            created.taskHint = .dictation
            created.contextualStrings = Array(hints.prefix(32))
            request = created
        } else { request = nil }
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let audioContext = CueAudioTapContext(request: request) { [weak self] power in
            self?.onPower?(power)
        }
        input.installTap(onBus: 0, bufferSize: 1_024, format: format,
                         block: cueAudioTapBlock(context: audioContext))
        if let recognizer, let request {
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let result else { _ = error; return }
                let text = result.bestTranscription.formattedString
                let confidence = result.bestTranscription.segments.last?.confidence ?? 0
                Task { @MainActor [weak self] in self?.onTranscript?(text, confidence, generation) }
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        if engine.inputNode.numberOfInputs > 0 { engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
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
    @State private var voicePosition: Double = 0
    @State private var lastTick = Date.now
    @State private var transcriptGeneration = 0
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
        }
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
        VStack(spacing: 5) {
            if complete {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: AgentID.cue.colorHex))
                Text("Script complete").font(.system(size: 12, weight: .semibold))
                HStack { Button("Restart") { restart() }; Button("Done") { exitCue() } }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        cueText
                            .padding(.vertical, 22)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: readPosition) { _, value in
                        guard alignment.tokens.indices.contains(value) else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { proxy.scrollTo(value, anchor: .center) }
                    }
                }
                .contentShape(Rectangle())
                HStack(spacing: 8) {
                    Button(paused ? "Resume" : "Pause") { paused.toggle(); lastTick = .now }
                    Button("Restart") { restart() }
                    textSizeMenu
                    if mode != .wordTracking {
                        Slider(value: $speed, in: 60...260, step: 10).frame(maxWidth: 72).help("Reading speed")
                    }
                    Spacer()
                    Text("\(min(readPosition, alignment.tokens.count)) / \(alignment.tokens.count)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.58))
                    Button("Done") { exitCue() }.help("Done and close Cue")
                }
                .buttonStyle(.bordered).controlSize(.mini)
            }
        }
        .foregroundStyle(.white.opacity(0.93))
        .padding(.horizontal, 2)
        .task(id: isActive) {
            guard isActive, mode != .wordTracking, !complete else { return }
            while !Task.isCancelled && isActive && !complete {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                if mode == .classic { advanceClassic() }
                else { advanceVoicePaced() }
            }
        }
        .onKeyPress(.space) {
            guard mode != .wordTracking else { return .ignored }
            paused.toggle(); return .handled
        }
    }

    private var cueText: some View {
        let ns = script as NSString
        return CueFlowLayout(spacing: 4, lineSpacing: 8) {
            ForEach(Array(alignment.tokens.enumerated()), id: \.offset) { index, token in
                let end = index + 1 < alignment.tokens.count ? alignment.tokens[index + 1].range.location : ns.length
                let range = NSRange(location: token.range.location, length: max(0, end - token.range.location))
                let fragment = range.location <= ns.length && NSMaxRange(range) <= ns.length ? ns.substring(with: range) : token.text
                Text(fragment)
                    .font(.system(size: textSize.points, weight: .medium, design: .rounded))
                    .foregroundStyle(index < readPosition ? .white.opacity(0.56) : (index == readPosition ? .black : .white.opacity(0.92)))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(index == readPosition ? Color(hex: AgentID.cue.colorHex) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .id(index)
                    .onTapGesture { jump(to: index) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func begin() {
        alignment = CueTextAlignment(script: script)
        readPosition = 0
        complete = false
        paused = false
        errorMessage = nil
        guard !alignment.tokens.isEmpty else { errorMessage = "Add some words to the script first."; return }
        classicClock = CueClassicClock()
        voicePosition = 0
        if mode == .classic { isActive = true; lastTick = .now; return }
        Task {
            do {
                speech.onTranscript = { text, confidence, generation in
                    guard isActive, mode == .wordTracking else { return }
                    let value = alignment.consume(text, confidence: confidence, generation: generation)
                    readPosition = min(max(0, value), max(0, alignment.tokens.count - 1))
                    if alignment.isFinished { complete = true; speech.stop() }
                }
                speech.onPower = { power in
                    _ = voiceState.update(power: power)
                }
                try await speech.start(locale: activeLocale, hints: alignment.upcomingContextWords,
                                       generation: alignment.generation, recognizeWords: mode == .wordTracking)
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

    private func advanceVoicePaced() {
        let now = Date.now
        let delta = now.timeIntervalSince(lastTick)
        lastTick = now
        guard !paused, voiceState.isSpeaking else { return }
        voicePosition = min(Double(alignment.tokens.count), voicePosition + delta * speed / 60)
        let next = Int(voicePosition)
        if next > readPosition { readPosition = next; if next >= alignment.tokens.count { complete = true; speech.stop() } }
    }

    private func jump(to index: Int) {
        guard isActive else { return }
        _ = alignment.jump(to: index)
        readPosition = index
        voicePosition = Double(index)
        if mode == .wordTracking {
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
        voicePosition = 0
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
