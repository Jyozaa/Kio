import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import CompanionCore

private struct EarlyVoiceClause {
    let text: String
    let step: SemanticVoiceStep
}

@MainActor
final class CompanionModel: ObservableObject {
    static let blobDiameter: CGFloat = 48
    @Published var goal = ""
    @Published var target = ""
    @Published var reviewVoiceTranscript = UserDefaults.standard.bool(forKey: "reviewVoiceTranscript")
    @Published var status = TaskStatus()

    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var helperSessionID = UUID()
    private var recoveryGeneration = UUID()
    private var runtimeRecoveryInFlight = false
    private var lastRuntimeRecoveryAt = Date.distantPast
    private var pendingVoiceGoal: String?
    private var activeEarlyVoiceStep: EarlyVoiceClause?
    private var activeEarlyVoiceTaskID: String?
    private var queuedEarlyVoiceSteps: [EarlyVoiceClause] = []
    private var completedEarlyVoiceSteps: [EarlyVoiceClause] = []
    private var completedEarlyVoiceStepIDs = Set<String>()
    private var browserPreparationAttempted = false
    var browserPreparationInFlight = false
    private let overlay = NotchOverlayController()
    private weak var voiceController: VoiceController?
    private var dismissTask: Task<Void, Never>?

    func setReviewVoiceTranscript(_ enabled: Bool) {
        reviewVoiceTranscript = enabled
        UserDefaults.standard.set(enabled, forKey: "reviewVoiceTranscript")
    }

    func launch() {
        if let process, process.isRunning { return }
        if process != nil { stopHelperProcess() }
        let environment = ProcessInfo.processInfo.environment
        let cuaSocket: String?
        do { cuaSocket = try EmbeddedCUASupervisor.shared.startIfBundled() }
        catch {
            status.fail(error.localizedDescription)
            refreshOverlay()
            return
        }
        guard let executable = HelperConfiguration.executable else {
            status.fail("Kio's bundled helper is missing. Reinstall the application."); return
        }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["-I", "-B", "-m", "companion_agent"]
        child.environment = HelperConfiguration.environment(cuaSocketPath: cuaSocket)
        if environment["COMPANION_DEMO"] == "1" { child.arguments?.append("--demo") }
        let stdinPipe = Pipe(); let stdoutPipe = Pipe()
        child.standardInput = stdinPipe; child.standardOutput = stdoutPipe
        child.standardError = FileHandle.standardError
        let sessionID = UUID()
        helperSessionID = sessionID
        do {
            try child.run()
            process = child; input = stdinPipe.fileHandleForWriting
            let handle = stdoutPipe.fileHandleForReading
            reader = Task.detached { [weak self] in
                var buffer = Data()
                while !Task.isCancelled {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let end = buffer.firstIndex(of: 10) {
                        let line = buffer.prefix(upTo: end)
                        buffer.removeSubrange(...end)
                        do {
                            let message = try Message.decode(Data(line))
                            await self?.receive(message)
                        } catch {
                            await self?.failure("Invalid helper response.")
                            return
                        }
                    }
                    if buffer.count > 65536 {
                        await self?.failure("Helper response exceeded limit."); return
                    }
                }
                if !Task.isCancelled { await self?.helperDisconnected(sessionID: sessionID) }
            }
            send(Message(kind: "health", taskID: "startup-\(UUID().uuidString)"))
        } catch { status.fail("Could not launch the local helper. Reinstall Kio or retry.") }
    }

    func receive(_ message: Message) {
        let browserMarker = "[KIO_BROWSER_ACCESS_REQUIRED] "
        let browserAccessRequired = message.text.hasPrefix(browserMarker)
        guard message.task_id == status.taskID else { return }
        if message.kind == "error", message.error_code == "runtime_transport_lost" {
            recoverLocalRuntime(reason: "Computer-use runtime disconnected. Restarting it now…")
            return
        }
        status.apply(message)
        if message.kind == "result", message.status == "completed",
           let activeEarlyVoiceStep, message.task_id == activeEarlyVoiceTaskID {
            completedEarlyVoiceSteps.append(activeEarlyVoiceStep)
            completedEarlyVoiceStepIDs.insert(activeEarlyVoiceStep.step.id)
            self.activeEarlyVoiceStep = nil
            activeEarlyVoiceTaskID = nil
        } else if status.taskID == nil, activeEarlyVoiceStep != nil,
                  message.task_id == activeEarlyVoiceTaskID {
            self.activeEarlyVoiceStep = nil
            activeEarlyVoiceTaskID = nil
            queuedEarlyVoiceSteps.removeAll()
        }
        refreshOverlay()
        if browserAccessRequired && !browserPreparationAttempted && !browserPreparationInFlight {
            prepareBrowserAccessAutomatically()
        }
        if status.state == .completed {
            // An early preparation step may finish while the microphone is
            // still listening.  Keep the pill alive until that voice session
            // and any queued task have actually ended.
            let keepVisible = voiceController.map {
                [.permission, .listening, .transcribing, .review].contains($0.state.phase)
            } == true || pendingVoiceGoal != nil
            dismissTask?.cancel()
            if keepVisible {
                refreshOverlay()
            } else {
                dismissTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    self?.overlay.hide()
                }
            }
        } else if status.state == .answered {
            dismissTask?.cancel()
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(7))
                guard !Task.isCancelled else { return }
                self?.overlay.hide()
            }
        } else if status.state == .error || status.state == .needsUser {
            dismissTask?.cancel()
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.overlay.hide()
            }
        }
        if status.taskID == nil {
            if let pending = pendingVoiceGoal {
                pendingVoiceGoal = nil
                submitFinalVoiceGoal(pending)
            } else if status.state == .completed {
                startNextEarlyVoiceStep()
            }
        }
    }

    func failure(_ message: String) {
        status.fail(message)
        stopHelperProcess()
        refreshOverlay()
    }

    func recoverLocalRuntime(reason: String) {
        guard !runtimeRecoveryInFlight else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRuntimeRecoveryAt) >= 15 else {
            status.fail("Kio's computer-use runtime disconnected again. Quit and reopen Kio.")
            stopHelperProcess()
            refreshOverlay()
            return
        }

        runtimeRecoveryInFlight = true
        lastRuntimeRecoveryAt = now
        let generation = UUID()
        recoveryGeneration = generation
        dismissTask?.cancel()
        clearEarlyVoicePlan()
        voiceController?.cancel()
        status.fail(reason)
        refreshOverlay()
        stopHelperProcess()

        do {
            _ = try EmbeddedCUASupervisor.shared.restart()
        } catch {
            runtimeRecoveryInFlight = false
            status.fail("Kio couldn't restart its computer-use runtime. Quit and reopen Kio.")
            refreshOverlay()
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.recoveryGeneration == generation else { return }
            self.launch()
            self.runtimeRecoveryInFlight = false
            if self.process != nil {
                self.status.fail("Kio restarted its computer-use runtime. Retry the interrupted request.")
            }
            self.refreshOverlay()
        }
    }

    private func helperDisconnected(sessionID: UUID) {
        guard helperSessionID == sessionID else { return }
        recoverLocalRuntime(reason: "Kio's helper disconnected. Restarting the local runtime…")
    }

    private func stopHelperProcess() {
        helperSessionID = UUID()
        reader?.cancel()
        reader = nil
        try? input?.close()
        input = nil
        let child = process
        process = nil
        guard let child, child.isRunning else { return }
        child.terminate()
        let deadline = Date().addingTimeInterval(1.5)
        while child.isRunning && Date() < deadline { usleep(25_000) }
        if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
    }

    func submit() { submit(resetBrowserPreparation: true) }

    private func submit(resetBrowserPreparation: Bool) {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              status.taskID == nil else { return }
        dismissTask?.cancel()
        if resetBrowserPreparation { browserPreparationAttempted = false }
        launch()
        guard process != nil else { refreshOverlay(); return }
        let id = UUID().uuidString
        status.start(id)
        if activeEarlyVoiceStep != nil { activeEarlyVoiceTaskID = id }
        showOverlay(voice: voiceController)
        send(Message(kind: "command", taskID: id, text: goal, target: target))
    }

    func stop() {
        guard let id = status.taskID else { return }
        send(Message(kind: "cancel", taskID: id))
    }

    private func prepareBrowserAccessAutomatically() {
        guard !browserPreparationAttempted, !browserPreparationInFlight else { return }
        browserPreparationAttempted = true
        browserPreparationInFlight = true
        status.reset()
        status.start(UUID().uuidString)
        status.fail("Preparing browser access…")
        refreshOverlay()
        do {
            _ = try EmbeddedCUASupervisor.shared.restart(allowExistingProfile: true)
            browserPreparationInFlight = false
            status.reset()
            submit(resetBrowserPreparation: false)
        } catch {
            browserPreparationInFlight = false
            let requestedTarget = target
            target = "__kio_force_ax__"
            status.reset()
            submit(resetBrowserPreparation: false)
            target = requestedTarget
        }
    }

    func submitVoiceGoal(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if status.taskID != nil {
            pendingVoiceGoal = text
            if activeEarlyVoiceStep == nil { stop() }
        } else {
            submitFinalVoiceGoal(text)
        }
    }

    func cancelPendingVoiceGoal() { pendingVoiceGoal = nil }

    func submitStableVoiceClause(_ text: String) {
        guard let step = SemanticVoiceStepParser.parse(text),
              !completedEarlyVoiceStepIDs.contains(step.id),
              activeEarlyVoiceStep?.step.id != step.id,
              !queuedEarlyVoiceSteps.contains(where: { $0.step.id == step.id }) else { return }
        let clause = EarlyVoiceClause(text: text, step: step)
        if status.taskID != nil || activeEarlyVoiceStep != nil {
            queuedEarlyVoiceSteps.append(clause)
            return
        }
        startEarlyVoiceStep(clause)
    }

    private func startEarlyVoiceStep(_ clause: EarlyVoiceClause) {
        guard status.taskID == nil else { queuedEarlyVoiceSteps.insert(clause, at: 0); return }
        activeEarlyVoiceStep = clause
        status.reset()
        goal = clause.text
        submit()
    }

    private func startNextEarlyVoiceStep() {
        guard status.taskID == nil, activeEarlyVoiceStep == nil,
              pendingVoiceGoal == nil, !queuedEarlyVoiceSteps.isEmpty else { return }
        let next = queuedEarlyVoiceSteps.removeFirst()
        guard !completedEarlyVoiceStepIDs.contains(next.step.id) else {
            startNextEarlyVoiceStep()
            return
        }
        startEarlyVoiceStep(next)
    }

    private func submitFinalVoiceGoal(_ text: String) {
        var remainder = text
        for clause in completedEarlyVoiceSteps {
            remainder = remainingVoiceGoal(after: clause, in: remainder)
        }
        clearEarlyVoicePlan()
        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        status.reset()
        goal = remainder
        submit()
    }

    private func remainingVoiceGoal(after clause: EarlyVoiceClause, in final: String) -> String {
        let finalTrimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let finalClause = SemanticVoiceStepParser.parseAll(finalTrimmed)
            .first(where: { $0.id == clause.step.id }),
              let range = finalTrimmed.range(of: finalClause.sourceText, options: .caseInsensitive) else {
            return finalTrimmed
        }
        let prefix = String(finalTrimmed[..<range.lowerBound])
        let suffix = String(finalTrimmed[range.upperBound...])
        return Self.stripVoiceStepConnector([prefix, suffix].filter { !$0.isEmpty }.joined(separator: " "))
    }

    private static func stripVoiceStepConnector(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let prefixes = [
            #"^(?:hey\s+)?kio[,]?\s*"#,
            #"^(?:can|could|would)\s+you\s+"#,
            #"^(?:and\s+then|after\s+that|and|then)\s+"#,
            #"^(?:once\s+you(?:'re|’re|\s+are)\s+there[,]?\s*)"#,
            #"^(?:can|could|would)\s+you\s+"#,
            #"^please\s+"#,
        ]
        for pattern in prefixes {
            value = value.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private func clearEarlyVoicePlan() {
        pendingVoiceGoal = nil
        queuedEarlyVoiceSteps.removeAll()
        completedEarlyVoiceSteps.removeAll()
        completedEarlyVoiceStepIDs.removeAll()
        activeEarlyVoiceStep = nil
        activeEarlyVoiceTaskID = nil
    }

    func attach(voice: VoiceController) {
        voiceController = voice
        voice.onTranscript = { [weak self, weak voice] text in
            guard let self, let voice else { return }
            if self.reviewVoiceTranscript { self.refreshOverlay() }
            else {
                voice.markSubmitted()
                self.submitVoiceGoal(text)
            }
        }
        voice.onStableClause = { [weak self] text in
            guard let self, !self.reviewVoiceTranscript else { return }
            self.submitStableVoiceClause(text)
        }
    }

    func showOverlay(voice: VoiceController? = nil) {
        if let voice { voiceController = voice }
        guard let voiceController else { return }
        dismissTask?.cancel()
        let size = overlaySize
        overlay.show(rootView: AnyView(KioOverlayView(model: self, voice: voiceController)), width: size.width, height: size.height)
    }

    func refreshOverlay() {
        guard overlay.isVisible, let voiceController else { return }
        let size = overlaySize
        overlay.update(rootView: AnyView(KioOverlayView(model: self, voice: voiceController)), width: size.width, height: size.height)
    }

    var overlaySize: CGSize {
        if voiceController?.state.phase == .listening || voiceController?.state.phase == .transcribing {
            return CGSize(width: Self.blobDiameter + 8, height: Self.blobDiameter + 8)
        }
        if status.answer != nil { return CGSize(width: 360, height: 112) }
        if status.state == .needsUser || status.state == .error ||
            voiceController?.state.phase == .failed || voiceController?.state.phase == .permission {
            return CGSize(width: 340, height: 100)
        }
        if voiceController?.state.phase == .review { return CGSize(width: 350, height: 108) }
        return CGSize(width: Self.blobDiameter + 8, height: Self.blobDiameter + 8)
    }

    func dismissOverlay() {
        dismissTask?.cancel()
        overlay.hide()
    }

    func cancelVoice() {
        cancelPendingVoiceGoal()
        if activeEarlyVoiceStep != nil { stop() }
        clearEarlyVoicePlan()
        voiceController?.cancel()
        if status.taskID == nil { overlay.hide() }
    }

    func startFreshVoiceSession(_ voice: VoiceController) {
        dismissTask?.cancel()
        clearEarlyVoicePlan()
        if status.taskID != nil { stop() }
        status.reset()
        voice.cancel()
        showOverlay(voice: voice)
        voice.begin()
    }

    func escapePressed() {
        guard let voice = voiceController,
              [.permission, .listening, .transcribing].contains(voice.state.phase) else { return }
        cancelVoice()
    }

    func send(_ message: Message) {
        do { try input?.write(contentsOf: message.encoded()) }
        catch { failure("Could not contact helper.") }
    }

    func shutdown() {
        dismissTask?.cancel(); stop(); stopHelperProcess()
        EmbeddedCUASupervisor.shared.stop()
        overlay.hide(animated: false)
    }
}

private struct KioOverlayView: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var voice: VoiceController
    @State private var appeared = false

    private var thinking: Bool { model.status.state == .working || voice.state.phase == .transcribing }
    private var voiceInProgress: Bool {
        [.permission, .listening, .transcribing, .review].contains(voice.state.phase)
    }
    private var blobMood: KioBlobMood {
        if voice.state.phase == .listening { return .listening }
        if voice.state.phase == .transcribing { return .thinking }
        if voice.state.phase == .failed || voice.state.phase == .permission ||
            (!voiceInProgress && (model.status.state == .needsUser || model.status.state == .error)) {
            return .attention
        }
        if thinking { return .thinking }
        if model.status.state == .completed || model.status.state == .answered { return .complete }
        return .idle
    }
    private var message: String? {
        if voice.state.phase == .failed { return voice.state.error }
        if voice.state.phase == .permission { return "Allow microphone access in Privacy & Security to speak to Kio." }
        if !voiceInProgress && (model.status.state == .needsUser || model.status.state == .error) {
            return model.status.text
        }
        return nil
    }

    var body: some View {
        Group {
            if let answer = model.status.answer {
                answerCard(answer)
            } else if voice.state.phase == .review {
                reviewCard
            } else if let message {
                messageCard(message)
            } else {
                blob
            }
        }
        .frame(width: model.overlaySize.width, height: model.overlaySize.height)
        .scaleEffect(appeared ? 1 : 0.78)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: appeared)
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
        .onChange(of: voice.state.phase) { _, phase in
            if phase == .listening { KioSoundEffects.play(.listening) }
            else if phase == .failed { KioSoundEffects.play(.attention) }
            model.refreshOverlay()
        }
        .onChange(of: model.status.state) { _, state in
            switch state {
            case .completed, .answered: KioSoundEffects.play(.complete)
            case .needsUser, .error: KioSoundEffects.play(.attention)
            case .idle, .working: break
            }
            model.refreshOverlay()
        }
        .onChange(of: model.status.answer) { _, _ in model.refreshOverlay() }
        .onReceive(NotificationCenter.default.publisher(for: .kioEscapeObserved)) { _ in model.escapePressed() }
    }

    private var blob: some View {
        KioAnimatedBlob(mood: blobMood, audioLevel: voice.audioLevel)
    }

    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Review transcript").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.cancelVoice(); model.dismissOverlay() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }.buttonStyle(.plain)
            }
            TextField("Transcript", text: $voice.transcript, axis: .vertical)
                .lineLimit(1...2).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Run") {
                    let text = voice.transcript
                    voice.markSubmitted()
                    model.submitVoiceGoal(text)
                }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.14)))
    }

    private func answerCard(_ answer: ObservationAnswerPayload) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(.ultraThinMaterial).overlay(Circle().fill(Color.cyan.opacity(0.2)))
                Image(systemName: "sparkle").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
            }.frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(answer.answer).font(.system(size: 13, weight: .medium)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                Text([answer.source_app, answer.source_window].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { model.dismissOverlay() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.14)))
    }

    private func messageCard(_ text: String) -> some View {
        HStack(spacing: 12) {
            blob
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 6) {
                Text("Kio").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(text).font(.system(size: 12)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if voice.state.phase == .permission || text.localizedCaseInsensitiveContains("microphone") {
                    Button("Microphone Settings") { openMicrophoneSettings() }.buttonStyle(.link).font(.system(size: 11))
                }
            }
            Spacer(minLength: 0)
            Button { model.dismissOverlay() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.14)))
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
}

@main
struct CompanionApp: App {
    @NSApplicationDelegateAdaptor(KioAppDelegate.self) private var appDelegate
    @StateObject private var model: CompanionModel
    @StateObject private var voice: VoiceController
    @StateObject private var shortcut: GlobalShortcutMonitor

    init() {
        let model = CompanionModel()
        let voice = VoiceController()
        let shortcut = GlobalShortcutMonitor.shared
        _model = StateObject(wrappedValue: model)
        _voice = StateObject(wrappedValue: voice)
        _shortcut = StateObject(wrappedValue: shortcut)
        KioRuntimeCoordinator.shared.register(model: model, voice: voice, shortcut: shortcut)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(shortcut: shortcut, appDelegate: appDelegate)
        } label: {
            Image(systemName: "waveform")
        }.menuBarExtraStyle(.window)

        Window("Kio Diagnostics", id: "diagnostics") {
            KioDiagnosticsView(model: model, voice: voice, shortcut: shortcut, appDelegate: appDelegate)
        }

        Settings {
            KioSettingsView(model: model, voice: voice, shortcut: shortcut)
        }
    }

}

@MainActor
private final class KioRuntimeCoordinator {
    static let shared = KioRuntimeCoordinator()

    private weak var model: CompanionModel?
    private weak var voice: VoiceController?
    private weak var shortcut: GlobalShortcutMonitor?
    private var applicationLaunched = false
    private var started = false

    func register(model: CompanionModel, voice: VoiceController, shortcut: GlobalShortcutMonitor) {
        self.model = model
        self.voice = voice
        self.shortcut = shortcut
        if applicationLaunched { startIfNeeded() }
    }

    func applicationDidFinishLaunching() {
        applicationLaunched = true
        startIfNeeded()
    }

    func shutdown() {
        guard started else { return }
        shortcut?.stop()
        model?.shutdown()
        started = false
    }

    private func startIfNeeded() {
        guard !started, let model, let voice, let shortcut else { return }
        started = true
        model.attach(voice: voice)
        EmbeddedCUASupervisor.shared.onUnexpectedExit = { [weak model] in
            model?.recoverLocalRuntime(reason: "Kio's local computer runtime stopped. Restarting it now…")
        }
        model.launch()
        shortcut.configure {
            if voice.state.phase == .listening { voice.release() }
            else if voice.state.phase == .ready || voice.state.phase == .failed {
                model.startFreshVoiceSession(voice)
            }
        }
    }
}

@MainActor
private final class KioAppDelegate: NSObject, NSApplicationDelegate {
    private var restartRequested = false
    private var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        KioRuntimeCoordinator.shared.applicationDidFinishLaunching()
        guard KioSetupProgress.load().needsFirstRun || !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() || !CGPreflightListenEventAccess() else { return }
        DispatchQueue.main.async { [weak self] in self?.showSetupWindow() }
    }

    func showSetupWindow(shortcut: GlobalShortcutMonitor = .shared) {
        if let setupWindow {
            setupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = SetupView(
            shortcut: shortcut,
            finished: { [weak self] in self?.closeSetupWindow() },
            restart: { [weak self] in self?.restartKio() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kio Setup"
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = window
    }

    func closeSetupWindow() {
        setupWindow?.close()
        setupWindow = nil
    }

    func restartKio() {
        restartRequested = true
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        KioRuntimeCoordinator.shared.shutdown()
        guard restartRequested else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var shortcut: GlobalShortcutMonitor
    let appDelegate: KioAppDelegate
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openSettings() }
        Button("Setup…") { appDelegate.showSetupWindow(shortcut: shortcut) }
        Button("Diagnostics…") { openWindow(id: "diagnostics") }
        Divider()
        Button("Quit Kio") { NSApp.terminate(nil) }
    }
}

private struct KioSettingsView: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var voice: VoiceController
    @ObservedObject var shortcut: GlobalShortcutMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Global shortcut", value: shortcut.status)
                Toggle("Subtle interface sounds", isOn: Binding(
                    get: { KioSoundEffects.isEnabled },
                    set: { KioSoundEffects.isEnabled = $0 }
                ))
                Toggle("Review voice transcript before running", isOn: Binding(
                    get: { model.reviewVoiceTranscript },
                    set: { model.setReviewVoiceTranscript($0) }
                ))
            }
            Section("Voice") {
                LabeledContent("Status", value: voice.state.phase.rawValue.capitalized)
                Text("Speech recognition runs locally on this Mac. Kio does not speak.")
                    .foregroundStyle(.secondary)
            }
            Section("Permissions") {
                Text("Kio needs Accessibility, Screen Recording, and Input Monitoring for computer use. Microphone access is used only for voice input.")
                    .foregroundStyle(.secondary)
                Button("Open Privacy & Security Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Section("Local Models") {
                Text("Voice and request understanding use local runtimes. Optional remote guidance is configured separately.")
                    .foregroundStyle(.secondary)
            }
            Section("Advanced") {
                Button("Open Diagnostics…") { openWindow(id: "diagnostics") }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 560)
        .padding(12)
    }
}

private struct KioDiagnosticsView: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var voice: VoiceController
    @ObservedObject var shortcut: GlobalShortcutMonitor
    let appDelegate: KioAppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Kio").font(.title2.bold())
            Text("Developer diagnostics").foregroundStyle(.secondary)
            TextField("Target app for computer use", text: $model.target).textFieldStyle(.roundedBorder)
            TextField("What would you like to do?", text: $model.goal)
                .textFieldStyle(.roundedBorder).onSubmit(model.submit).accessibilityIdentifier("goalInput")
            HStack {
                Button("Run", action: model.submit).disabled(model.status.taskID != nil)
                Button("Stop", action: model.stop).disabled(model.status.taskID == nil)
                Button("Reset") { model.status.reset() }.disabled(model.status.taskID != nil)
                Button("Setup…") { appDelegate.showSetupWindow(shortcut: shortcut) }
            }
            Toggle("Review voice transcript before running", isOn: Binding(
                get: { model.reviewVoiceTranscript }, set: { model.setReviewVoiceTranscript($0) }))
            HStack {
                Text("Hold to talk").padding(8).background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if model.status.state != .working { model.showOverlay(voice: voice); voice.begin() } }
                        .onEnded { _ in voice.release() })
                    .accessibilityElement(children: .ignore).accessibilityLabel("Hold to talk")
                    .accessibilityAddTraits(.isButton).accessibilityAction {
                        if voice.state.phase == .listening { voice.release() }
                        else if model.status.state != .working { model.showOverlay(voice: voice); voice.begin() }
                    }
                Text(voice.state.phase.rawValue).font(.caption)
                Button("Cancel voice") { model.cancelVoice() }
            }
            HStack { Text(shortcut.status).font(.caption).foregroundStyle(.secondary); Button("Enable global shortcut") { shortcut.requestPermission() } }
            Text(model.status.state.rawValue).font(.caption).foregroundStyle(.secondary)
            Text("Diagnostic code: \(model.status.errorCode ?? "none")")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.status.text).accessibilityIdentifier("taskStatus")
        }.padding(24).frame(width: 430).onAppear { model.launch() }
    }
}
