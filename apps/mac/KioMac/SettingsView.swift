import AppKit
import CoreImage.CIFilterBuiltins
import KioCore
import KioInference
import KioModel
import KioSync
import KioTools
import KioUI
import Security
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
    @State private var apiKeyEntry = ""
    @State private var intelligenceMessage: String?
    @State private var providerModels: [ProviderModel] = []
    @State private var showReelDiagnostics = false
    @ObservedObject private var intelligence = IntelligenceSettings.shared
    @ObservedObject private var model = LocalModelManager.shared
    @ObservedObject private var relay = LocalRelayManager.shared

    var body: some View {
        Form {
            generalSection
            intelligenceSection
            reelSection
            modelSection
            filesSection
            mobileSection
            privacySection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .navigationTitle("Kio Settings")
        .sheet(isPresented: $showReelDiagnostics) { ReelRuntimeDiagnosticsView() }
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

    private var intelligenceSection: some View {
        Section("Intelligence") {
            Picker("Provider", selection: Binding(get: { intelligence.provider }, set: { intelligence.select($0) })) {
                ForEach(IntelligenceProviderID.allCases) { provider in Text(provider.title).tag(provider) }
            }
            if intelligence.provider.keychainService != nil {
                SecureField(intelligence.hasKey ? "Saved key · enter to replace" : "API key", text: $apiKeyEntry)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                HStack {
                    Button("Save key") {
                        do { try intelligence.saveKey(apiKeyEntry); apiKeyEntry = ""; intelligenceMessage = "Key saved in Keychain." }
                        catch { intelligenceMessage = error.localizedDescription }
                    }.disabled(apiKeyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Test connection") {
                        Task {
                            do { intelligenceMessage = try await IntelligenceProviderClient.shared.testConnection() }
                            catch { intelligenceMessage = error.localizedDescription }
                        }
                    }.disabled(!intelligence.hasKey)
                    if intelligence.hasKey {
                        Button("Remove key", role: .destructive) {
                            do { try intelligence.removeKey(); intelligenceMessage = "Provider key removed." }
                            catch { intelligenceMessage = error.localizedDescription }
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Provider model identifier", text: $intelligence.modelIdentifier)
                        .textFieldStyle(.roundedBorder)
                    Button("Fetch models") {
                        Task {
                            do { providerModels = try await IntelligenceProviderClient.shared.listModels(); intelligenceMessage = "Loaded \(providerModels.count) model identifiers." }
                            catch { intelligenceMessage = error.localizedDescription }
                        }
                    }.disabled(!intelligence.hasKey)
                }
                if !providerModels.isEmpty {
                    Menu("Choose available model") {
                        ForEach(providerModels.prefix(100)) { model in Button(model.id) { intelligence.modelIdentifier = model.id } }
                    }
                }
                Text(intelligence.hasKey ? "Key saved in macOS Keychain for this provider." : "API key is not connected.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Picker("Content privacy", selection: $intelligence.privacyMode) {
                ForEach(ContentPrivacyMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            Text("Provider requests go directly from this Mac to the selected HTTPS provider. Keys stay in Keychain. There is no automatic provider fallback.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let intelligenceMessage { Text(intelligenceMessage).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }

    private var reelSection: some View {
        Section("Reel · online media") {
            LabeledContent("Status", value: ReelRuntime.isReady() ? "Ready" : "Installation damaged")
            LabeledContent("Media engine", value: "Bundled with Kio")
            if !ReelRuntime.isReady() {
                Text("Reinstall Kio to restore Reel’s bundled media runtime.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("Diagnostics…") { showReelDiagnostics = true }
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
                LabeledContent("App identity", value: Bundle.main.bundleIdentifier ?? "Unknown")
                LabeledContent("Installed at", value: Bundle.main.bundleURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                LabeledContent("Signing", value: signingAuthorities.first ?? "Ad hoc / unsigned")
                LabeledContent("Development identity stable", value: hasStableDevelopmentIdentity ? "Yes" : "No")
                LabeledContent("Mac", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Architecture", value: ProcessInfo.processInfo.machineArchitecture)
        }
    }

    private var signingAuthorities: [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code else { return [] }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
        let values = signingInformation as? [String: Any],
        let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate] else { return [] }

        return certificates.prefix(1).compactMap { SecCertificateCopySubjectSummary($0) as String? }
    }

    private var hasStableDevelopmentIdentity: Bool {
        signingAuthorities.contains {
            $0.hasPrefix("Apple Development:") || $0 == "Kio Local Development"
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

private struct ReelRuntimeDiagnosticsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reel Diagnostics").font(.headline)
            ForEach(Array(ReelRuntime.diagnostics.enumerated()), id: \.offset) { entry in
                let item = entry.element
                LabeledContent(item.name, value: "\(item.version) · \(item.available ? "Ready" : "Missing")")
            }
            Text("The media runtime is loaded from Kio.app. Gallery download support is not included in this build.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(minWidth: 360)
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
