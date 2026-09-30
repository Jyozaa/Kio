import AppKit
import CoreImage.CIFilterBuiltins
import KioCore
import KioInference
import KioSync
import KioUI
import SwiftUI

struct KioSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("kio.hoverExpansion") private var hoverExpansion = true
    @AppStorage("kio.reduceCharacterMotion") private var reduceCharacterMotion = false
    @AppStorage("kio.keepModelLoaded") private var keepModelLoaded = true
    @AppStorage("kio.relayURL") private var relayURL = ""
    @State private var showClearHistory = false
    @State private var showRemoveModel = false
    @State private var revokeDeviceID: String?
    @ObservedObject private var model = LocalModelManager.shared
    @ObservedObject private var relay = LocalRelayManager.shared

    var body: some View {
        Form {
            Section("General") {
                Toggle("Expand the notch on hover", isOn: $hoverExpansion)
                Toggle("Reduce Kio character motion", isOn: $reduceCharacterMotion)
                LabeledContent("Global shortcut", value: "⌥⌘K")
                Button("Open conversation window") { openWindow(id: "main") }
            }
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
                Toggle("Keep model loaded", isOn: $keepModelLoaded)
                    .onChange(of: keepModelLoaded) { _, value in model.updateKeepLoadedPreference(value) }
                Text("Stored in ~/Library/Application Support/Kio/Models. Preparation downloads from Hugging Face; planning and file processing run locally afterward.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                LabeledContent("Model cache", value: ByteCountFormatter.string(fromByteCount: model.installedSizeBytes, countStyle: .file))
                LabeledContent("Planner data", value: "Names, types, sizes and indexes only")
            }
            Section("Files") {
                LabeledContent("Default output", value: "Source folder or Downloads/Kio")
                Label("Preserve originals", systemImage: "lock.fill")
            }
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
            Section("Privacy") {
                Button("Clear history…", role: .destructive) { showClearHistory = true }
                Text("Conversation history and task context are stored on this Mac. Clear history removes them. Pairing credentials are protected in Keychain.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                LabeledContent("Mac", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Architecture", value: ProcessInfo.processInfo.machineArchitecture)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Kio Settings")
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
