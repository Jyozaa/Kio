import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import CompanionCore

@MainActor
final class SetupModel: ObservableObject {
    @Published var busy = false
    @Published var values: [String: String] = [:]
    @Published var message = "Checking Kio…"
    @Published var passed = false
    @Published var key = ""
    @Published var geminiModel = UserDefaults.standard.string(forKey: "geminiModel") ?? ""
    @Published var keyStatus = "Gemini is optional. Stored keys are never displayed."
    @Published var progress = KioSetupProgress.load()
    @Published var downloadProgress: Double?
    @Published var downloadStatus = ""
    @Published var restartRecommended = false
    @Published var microphoneStatus = "Not enabled"
    @Published var shortcutReady = false
    @Published var layaSize = "843 MB"
    @Published var voiceSize = "78 MB"

    private var process: Process?
    private var generation = 0
    private var lastPermissionState: (Bool, Bool)?
    private var result: [String: String]?

    var accessibilityReady: Bool { values["accessibility"] == "ready" }
    var screenCaptureReady: Bool { values["screen_recording"] == "ready" }
    var runtimeReady: Bool { values["driver"] == "ready" }
    var layaReady: Bool { values["laya"] == "ready" }
    var voiceReady: Bool { values["stt"] == "ready" }
    var perceptionReady: Bool { values["perception"] == "ready" }
    var isFirstRun: Bool { progress.needsFirstRun }
    var permissionsNeedRepair: Bool { !accessibilityReady || !screenCaptureReady || !shortcutReady }

    init() {
        layaSize = manifestSize("laya")
        voiceSize = manifestSize("stt")
        refreshMicrophonePermission()
    }

    func run(_ command: String) {
        guard !busy, let executable = HelperConfiguration.executable else { return }
        let socketPath: String?
        do { socketPath = try EmbeddedCUASupervisor.shared.startIfBundled() }
        catch { message = error.localizedDescription; return }
        busy = true
        passed = false
        result = nil
        downloadProgress = nil
        downloadStatus = ""
        generation += 1
        let token = generation
        message = command == "self-test" ? "Checking Kio without changing the desktop…" : "Checking Kio…"

        let child = Process()
        let output = Pipe()
        child.executableURL = executable
        child.arguments = ["-I", "-B", "-m", "companion_agent.setup", command, "--manifests", HelperConfiguration.manifests.path]
        child.environment = HelperConfiguration.environment(cuaSocketPath: socketPath)
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        do { try child.run(); process = child }
        catch { busy = false; message = "Kio could not start its local check. Retry."; return }

        Task.detached { [weak self] in
            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    await MainActor.run { self?.consume(line, command: command, token: token) }
                }
                if buffer.count > 65536 {
                    await MainActor.run { self?.fail("Setup response was too large.", token: token) }
                    child.terminate()
                    return
                }
            }
            if !buffer.isEmpty {
                await MainActor.run { self?.consume(buffer, command: command, token: token) }
            }
            child.waitUntilExit()
            let status = child.terminationStatus
            await MainActor.run { self?.finish(command: command, exitStatus: status, token: token) }
        }
    }

    func recheck() {
        refreshPermissions(restartDriverIfChanged: true)
        refreshMicrophonePermission()
        run("check")
    }

    func cancel() {
        generation += 1
        process?.terminate()
        process = nil
        busy = false
        downloadProgress = nil
        downloadStatus = ""
        message = "Setup stopped. You can retry."
    }

    func skip(_ stage: KioSetupStage) {
        progress.skip(stage)
        updateStage()
    }

    func setShortcutReady(_ ready: Bool) {
        shortcutReady = ready
        updateStage()
    }

    func finishSetup() {
        guard passed, !permissionsNeedRepair, !restartRecommended, layaReady else { return }
        progress.markReady()
        progress.save()
        UserDefaults.standard.set(true, forKey: "kioSetupComplete")
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openPrivacyPane("Privacy_Accessibility") }
    }

    func requestScreenRecording() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        _ = CGRequestScreenCaptureAccess()
        openPrivacyPane("Privacy_ScreenCapture")
    }

    func requestMicrophone() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshMicrophonePermission()
            updateStage()
        }
    }

    func refreshMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphoneStatus = "Ready"
        case .denied: microphoneStatus = "Off"
        case .restricted: microphoneStatus = "Unavailable on this Mac"
        case .notDetermined: microphoneStatus = "Optional"
        @unknown default: microphoneStatus = "Unavailable"
        }
    }

    func requestRestart(_ restart: () -> Void) { restart() }

    func refreshPermissions(restartDriverIfChanged: Bool) {
        let accessibility = AXIsProcessTrusted()
        let screenCapture = CGPreflightScreenCaptureAccess()
        values["accessibility"] = accessibility ? "ready" : "needed"
        values["screen_recording"] = screenCapture ? "ready" : "needed"
        values["permissions"] = accessibility && screenCapture ? "ready" : "needed"
        if !screenCapture {
            restartRecommended = false
        } else if let previous = lastPermissionState, !previous.1 {
            restartRecommended = true
        }
        if restartDriverIfChanged,
           let previous = lastPermissionState,
           previous != (accessibility, screenCapture), accessibility, screenCapture {
            do { _ = try EmbeddedCUASupervisor.shared.restart() }
            catch { message = error.localizedDescription }
        }
        lastPermissionState = (accessibility, screenCapture)
        updateStage()
    }

    func saveKey() {
        guard geminiModel.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            keyStatus = "Enter a valid Gemini model identifier."
            return
        }
        do {
            try KeychainStore.save(key)
            UserDefaults.standard.set(geminiModel, forKey: "geminiModel")
            key = ""
            keyStatus = "Key saved in macOS Keychain."
        } catch { key = ""; keyStatus = "Could not save key to macOS Keychain." }
    }

    func deleteKey() {
        do { try KeychainStore.delete(); key = ""; keyStatus = "Stored Gemini key deleted." }
        catch { keyStatus = "Could not delete Keychain item." }
    }

    private func consume(_ data: Data, command: String, token: Int) {
        guard token == generation,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if object["event"] as? String == "progress" {
            let downloaded = (object["downloaded"] as? NSNumber)?.int64Value ?? 0
            let total = (object["total"] as? NSNumber)?.int64Value ?? 0
            downloadProgress = total > 0 ? min(1, Double(downloaded) / Double(total)) : nil
            let model = object["model"] as? String == "Laya" ? "Local AI" : "Local Voice"
            downloadStatus = "\(model) · \(ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
            message = "Downloading \(model)…"
            return
        }
        if let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            result = decoded
        }
    }

    private func finish(command: String, exitStatus: Int32, token: Int) {
        guard token == generation else { return }
        busy = false
        process = nil
        downloadProgress = nil
        downloadStatus = ""
        if let result {
            values.merge(result) { _, new in new }
            message = result["message"] ?? (exitStatus == 0 ? "Kio is ready to check." : "Some checks need attention.")
            passed = command == "self-test" && result["status"] == "ready"
        } else {
            message = "Kio could not complete the check. Retry."
            passed = false
        }
        refreshPermissions(restartDriverIfChanged: false)
        updateStage()
    }

    private func fail(_ text: String, token: Int) {
        guard token == generation else { return }
        message = text
        busy = false
        passed = false
    }

    private func updateStage() {
        guard progress.needsFirstRun else { return }
        let next: KioSetupStage
        if !runtimeReady { next = .kioRuntime }
        else if !accessibilityReady { next = .accessibility }
        else if !screenCaptureReady { next = .screenCapture }
        else if !layaReady { next = .layaModel }
        else if !shortcutReady {
            next = .inputMonitoring
        } else if microphoneStatus == "Optional" && !progress.skippedOptionalStages.contains(.microphone) {
            next = .microphone
        } else if !voiceReady && !progress.skippedOptionalStages.contains(.voiceModel) {
            next = .voiceModel
        } else if !passed { next = .selfTest }
        else { next = .ready }
        if progress.stage != next {
            progress.advance(to: next)
            progress.save()
        }
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func manifestSize(_ name: String) -> String {
        let path = HelperConfiguration.manifests.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        let files = object["files"] as? [[String: Any]] ?? [object]
        let bytes = files.compactMap { ($0["size"] as? NSNumber)?.int64Value }.reduce(0, +)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct SetupView: View {
    @StateObject private var setup = SetupModel()
    @ObservedObject var shortcut: GlobalShortcutMonitor
    let finished: () -> Void
    let restart: () -> Void

    private var repairOnly: Bool { !setup.isFirstRun && setup.permissionsNeedRepair }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(repairOnly ? "Kio needs access" : setup.isFirstRun ? "Welcome to Kio" : "Kio Setup")
                        .font(.title2.bold())
                    Text(repairOnly
                        ? "Restore the missing permission below. Your setup and local models are unchanged."
                        : "Kio works quietly on this Mac. Typed commands are always available; voice is optional.")
                        .foregroundStyle(.secondary)
                }

                if setup.isFirstRun {
                    VStack(alignment: .leading, spacing: 9) {
                        checklist("Kio Core", ready: setup.runtimeReady)
                        checklist("Accessibility", ready: setup.accessibilityReady)
                        checklist("Screen & System Audio Recording", ready: setup.screenCaptureReady)
                        checklist("Local AI", ready: setup.layaReady)
                        checklist("Visual Understanding", ready: setup.perceptionReady, optional: true)
                        checklist("Global Shortcut", ready: shortcut.isEnabled)
                        checklist("Microphone", ready: setup.microphoneStatus == "Ready", optional: true)
                        checklist("Voice Model", ready: setup.voiceReady, optional: true)
                    }
                    .padding(14)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                }

                if !setup.accessibilityReady {
                    setupCard("Accessibility", detail: "Lets Kio read controls and use the action you asked for.", status: "Needed") {
                        Button("Enable Accessibility", action: setup.requestAccessibility)
                    }
                }
                if !setup.screenCaptureReady {
                    setupCard("Screen & System Audio Recording", detail: "Lets Kio inspect a window when its controls are not available.", status: "Needed") {
                        Button("Enable Screen Access", action: setup.requestScreenRecording)
                    }
                }
                if repairOnly && !shortcut.isEnabled {
                    setupCard("Global Shortcut", detail: "Option + Command summons Kio from any app.", status: "Needed") {
                        Button("Enable Global Shortcut") { shortcut.requestPermission() }
                    }
                    Text(shortcut.status).font(.caption).foregroundStyle(.secondary)
                }
                if repairOnly {
                    Text("Running app: \(Bundle.main.bundleURL.path)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("If Settings already shows Kio as on but this still says Needed, the grant may belong to another Kio build. Enable this exact app, restart Kio, then choose Check Setup. Input Monitoring is separate and is required for the global shortcut.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if setup.restartRecommended {
                    HStack {
                        Text("Restart Kio to apply screen access.").font(.callout)
                        Spacer()
                        Button("Restart Kio", action: restart)
                    }
                    .padding(12)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }

                if !repairOnly {
                    setupCard("Local AI", detail: "Runs decisions on this Mac. Download size: \(setup.layaSize).", status: setup.values["laya"] == "ready" ? "Ready" : "Not installed") {
                        if setup.busy { Button("Cancel", action: setup.cancel) }
                        else { Button(setup.layaReady ? "Verify Local AI" : "Download Local AI") { setup.run("install-laya") } }
                    }
                    setupCard("Visual Understanding", detail: "Uses the signed CUA Perception extension when structured controls are insufficient. Screenshots stay local to CUA.", status: setup.perceptionReady ? "Ready" : "Optional") {
                        Text("Managed by CUA Driver").font(.caption)
                    }
                    if let value = setup.downloadProgress {
                        ProgressView(value: value)
                        Text(setup.downloadStatus).font(.caption).foregroundStyle(.secondary)
                    }

                    setupCard("Global Shortcut", detail: "Option + Command summons Kio from any app.", status: shortcut.isEnabled ? "Ready" : "Needed") {
                        if !shortcut.permissionGranted {
                            Button("Enable Global Shortcut") { shortcut.requestPermission() }
                        }
                    }
                    Text(shortcut.status).font(.caption).foregroundStyle(.secondary)

                    setupCard("Microphone", detail: "Used only for local voice commands. Audio is processed on this Mac.", status: setup.microphoneStatus) {
                        if setup.microphoneStatus == "Optional" || setup.microphoneStatus == "Off" {
                            Button("Enable Microphone", action: setup.requestMicrophone)
                            Button("Skip", action: { setup.skip(.microphone) })
                        }
                    }

                    setupCard("Voice Model", detail: "Optional local speech recognition. Download size: \(setup.voiceSize).", status: setup.voiceReady ? "Ready" : "Optional") {
                        if setup.busy { Button("Cancel", action: setup.cancel) }
                        else if !setup.voiceReady {
                            Button("Download Voice Model") { setup.run("install-stt") }
                            Button("Skip", action: { setup.skip(.voiceModel) })
                        }
                    }

                    DisclosureGroup("Optional Gemini") {
                        Text("Gemini can help with selected difficult tasks. Kio never speaks or lets Gemini control the Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField("Gemini API key", text: $setup.key)
                        TextField("Gemini model identifier", text: $setup.geminiModel)
                        HStack { Button("Save / replace key", action: setup.saveKey); Button("Delete key", action: setup.deleteKey) }
                        Text(setup.keyStatus).font(.caption)
                    }
                }

                HStack {
                    Button("Check Setup", action: setup.recheck).disabled(setup.busy)
                    Button("Run Self-Test") { setup.run("self-test") }.disabled(setup.busy)
                    if setup.busy { Button("Cancel", action: setup.cancel) }
                }
                Text(setup.message).font(.callout)
                if let voiceTest = setup.values["voice_test"], voiceTest != "not_run" {
                    Group {
                        switch voiceTest {
                        case "ready": Text("Local voice check passed.")
                        case "skipped": Text("Local voice was skipped.")
                        default: Text("Local voice is optional and needs attention.")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    if setup.isFirstRun {
                        Button("Continue to Kio") {
                            setup.finishSetup()
                            finished()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!setup.passed || setup.permissionsNeedRepair || setup.restartRecommended || !setup.layaReady || setup.busy)
                    } else {
                        Button("Done", action: finished).buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(width: 560, height: 700)
        .onAppear {
            setup.refreshPermissions(restartDriverIfChanged: false)
            setup.setShortcutReady(shortcut.permissionGranted)
            setup.run("check")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            setup.recheck()
            shortcut.refreshPermission()
            setup.setShortcutReady(shortcut.permissionGranted)
        }
        .onDisappear { setup.cancel() }
    }

    private func checklist(_ title: String, ready: Bool, optional: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ready ? "checkmark.circle.fill" : optional ? "circle.dashed" : "circle")
                .foregroundStyle(ready ? .green : .secondary)
            Text(title)
            if optional { Text("Optional").font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }.font(.callout)
    }

    private func setupCard<Actions: View>(
        _ title: String,
        detail: String,
        status: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12, content: actions)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
