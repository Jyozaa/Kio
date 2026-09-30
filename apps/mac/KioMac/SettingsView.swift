import AppKit
import CoreImage.CIFilterBuiltins
import KioCore
import KioInference
import KioSync
import KioTools
import KioUI
import ServiceManagement
import SwiftUI

struct KioSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("kio.hoverExpansion") private var hoverExpansion = true
    @AppStorage("kio.hoverDwellMilliseconds") private var hoverDwellMilliseconds = 150
    @AppStorage("kio.reduceCharacterMotion") private var reduceCharacterMotion = false
    @AppStorage("kio.modelUnloadMinutes") private var modelUnloadMinutes = 0
    @AppStorage("kio.shortcutPreset") private var shortcutPreset = "option-command-k"
    @AppStorage("kio.relayURL") private var relayURL = ""
    @State private var showClearHistory = false
    @State private var showRemoveModel = false
    @State private var revokeDeviceID: String?
    @State private var launchAtLogin = false
    @State private var loginError: String?
    @State private var pairingLinkCopied = false
    @State private var outputLocationDescription = OutputLocation.preferenceDescription
    @State private var outputLocationError: String?
    @ObservedObject private var model = LocalModelManager.shared
    @ObservedObject private var relay = LocalRelayManager.shared

    var body: some View {
        Form {
            generalSection
            modelSection
            filesSection
            mobileSection
            privacySection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .navigationTitle("Kio Settings")
        .task {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .confirmationDialog("Clear history?", isPresented: $showClearHistory, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { KioWorkspace.shared.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved conversation history and task context from this Mac.")
        }
        .confirmationDialog("Remove the local model?", isPresented: $showRemoveModel, titleVisibility: .visible) {
            Button("Remove Model", role: .destructive) { try? model.removeModel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the downloaded model from this Mac. You can download it again later.")
        }
        .confirmationDialog("Revoke this phone?", isPresented: Binding(get: { revokeDeviceID != nil }, set: { if !$0 { revokeDeviceID = nil } }), titleVisibility: .visible) {
            Button("Revoke Phone", role: .destructive) {
                if let revokeDeviceID { Task { await relay.revokePhone(revokeDeviceID) } }
                revokeDeviceID = nil
            }
            Button("Cancel", role: .cancel) { revokeDeviceID = nil }
        } message: {
            Text("This phone will no longer be able to send requests or receive messages from this Mac.")
        }
    }

    private var generalSection: some View {
        Section("General") {
                Toggle("Expand the notch on hover", isOn: $hoverExpansion)
                Picker("Hover delay", selection: $hoverDwellMilliseconds) {
                    Text("Immediate").tag(0)
                    Text("150 ms").tag(150)
                    Text("300 ms").tag(300)
                }
                .disabled(!hoverExpansion)
                Toggle("Reduce Kio character motion", isOn: $reduceCharacterMotion)
                Picker("Global shortcut", selection: $shortcutPreset) {
                    Text("⌥⌘K").tag("option-command-k")
                    Text("⌥⌘Space").tag("option-command-space")
                    Text("⌃⌥K").tag("control-option-k")
                }
                .onChange(of: shortcutPreset) { _, value in (NSApp.delegate as? KioAppDelegate)?.setShortcutPreset(value) }
                Toggle("Launch Kio at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in setLaunchAtLogin(enabled) }
                ))
                if let loginError { Text(loginError).font(.system(size: 11)).foregroundStyle(.red) }
                Button("Open conversation window") { openWindow(id: "main") }
            }
    }

    private var modelSection: some View {
        Section("Local model") {
                LabeledContent("Model", value: "Qwen3.5 2B · 4-bit")
                LabeledContent("Status", value: model.statusDescription)
                if let progress = model.preparationProgress {
                    ProgressView(value: progress)
                        .accessibilityLabel("Local model download and preparation progress")
                }
                HStack {
                    Button(model.isInstalled ? "Load local model" : "Download model · 1.72 GB") {
                        Task { await model.prepare() }
                    }
                    .disabled(model.isPreparing || model.statusDescription == "Loaded on this Mac")
                    if model.isInstalled {
                        Button("Remove…", role: .destructive) { showRemoveModel = true }
                            .disabled(model.isPreparing)
                    }
                }
                Picker("Unload when idle", selection: $modelUnloadMinutes) {
                    Text("Keep loaded").tag(0)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
                .onChange(of: modelUnloadMinutes) { _, value in model.updateUnloadPreference(value) }
                Text("Stored in ~/Library/Application Support/Kio/Models. Preparation downloads from Hugging Face; planning and file processing run locally afterward.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                LabeledContent("Model cache", value: ByteCountFormatter.string(fromByteCount: model.installedSizeBytes, countStyle: .file))
                LabeledContent("Planner data", value: "Names, types, sizes and indexes only")
            }
    }

    private var filesSection: some View {
        Section("Files") {
                LabeledContent("Output location", value: outputLocationDescription)
                HStack {
                    Button("Choose Folder…") { chooseOutputFolder() }
                    Button("Restore Default") {
                        OutputLocation.restoreDefault()
                        outputLocationDescription = OutputLocation.preferenceDescription
                        outputLocationError = nil
                    }
                    .disabled(outputLocationDescription == "Source folder or Downloads/Kio")
                }
                if let outputLocationError {
                    Text(outputLocationError).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
                }
                Text("Kio writes new files here when a custom location is selected. The default uses the source folder or Downloads/Kio.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Label("Preserve originals", systemImage: "lock.fill")
            }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose where Kio should save new results."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            try OutputLocation.setCustomFolder(folder)
            outputLocationDescription = OutputLocation.preferenceDescription
            outputLocationError = nil
        } catch {
            outputLocationError = error.localizedDescription
        }
    }

    private var mobileSection: some View {
        Section("Mobile") {
                TextField("PWA and relay URL", text: $relayURL, prompt: Text("https://kio-relay.workers.dev"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                HStack {
                    Button("Connect") { relay.configure(relayURL: relayURL) }
                        .disabled(relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(relay.isPairing ? "Creating code…" : "Pair phone…") {
                        Task { await relay.createPairing() }
                    }
                    .disabled(!relay.isConfigured || relay.isPairing)
                }
                LabeledContent("Status", value: relay.statusMessage)
                if let pairingURL = relay.pairingURL, let expiry = relay.pairingExpiresAt, expiry > .now {
                    HStack(alignment: .center, spacing: 14) {
                        QRCodeView(value: pairingURL.absoluteString)
                            .frame(width: 132, height: 132)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Scan with your phone camera").font(.system(size: 12, weight: .semibold))
                            Text("One use · expires in five minutes").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text("The QR code carries a one-time pairing token and this Mac's public key. Its private key stays in Keychain.")
                                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(pairingURL.absoluteString, forType: .string)
                                pairingLinkCopied = true
                            } label: {
                                Label(pairingLinkCopied ? "Pairing link copied" : "Copy pairing link", systemImage: pairingLinkCopied ? "checkmark" : "link")
                            }
                            .buttonStyle(.bordered)
                            .help("Copy the one-time pairing link to use in a browser on this Mac.")
                            .accessibilityIdentifier("copy-pairing-link")
                        }
                    }
                    .padding(.vertical, 4)
                }
                if !relay.devices.isEmpty {
                    ForEach(relay.devices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName).font(.system(size: 12, weight: .medium))
                                Text("Paired phone").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) { revokeDeviceID = device.id }
                        }
                    }
                }
                if let error = relay.lastError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
                }
                Text("Phone requests are queued on the encrypted relay when this Mac is offline. The relay sees device metadata and ciphertext only; tools and the local model run on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
    }

    private var privacySection: some View {
        Section("Privacy") {
                Button("Clear history…", role: .destructive) { showClearHistory = true }
                Text("Conversation history and task context are stored on this Mac. Clear history removes them. Pairing credentials are protected in Keychain.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
                LabeledContent("Kio version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                LabeledContent("Mac", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Architecture", value: ProcessInfo.processInfo.machineArchitecture)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginError = error.localizedDescription
        }
    }
}

private struct QRCodeView: View {
    let value: String

    var body: some View {
        Group {
            if let image = Self.makeImage(value) { Image(nsImage: image).interpolation(.none).resizable().scaledToFit() }
            else { ContentUnavailableView("QR unavailable", systemImage: "qrcode") }
        }
        .padding(7)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.08), lineWidth: 1))
        .accessibilityLabel("One-time Kio phone pairing QR code")
    }

    private static func makeImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        #if arch(arm64)
        "Apple Silicon"
        #else
        "Unsupported"
        #endif
    }
}
