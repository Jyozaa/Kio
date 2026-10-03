import AppKit
import KioModel
import KioTools
import ServiceManagement
import SwiftUI

struct KioSettingsView: View {
    @AppStorage("kio.shortcutPreset") private var shortcutPreset = "option-command-k"
    @AppStorage("kio.reduceMotion") private var reduceMotion = false
    @AppStorage("kio.clipboard.enabled") private var clipboardEnabled = false
    @AppStorage("kio.clipboard.retentionDays") private var retentionDays = 7
    @AppStorage("kio.clipboard.maximumEntries") private var maximumEntries = 200
    @State private var excludedBundleIDs: [String] = []
    @AppStorage("kio.news.enabled") private var newsEnabled = true
    @AppStorage("kio.appearance") private var appearance = "system"
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var message: String?
    @State private var outputFolder = OutputLocation.preferenceDescription
    @State private var exclusionText = ""

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
                .onChange(of: appearance) { _, value in
                    NSApp.appearance = value == "system" ? nil : NSAppearance(named: value == "dark" ? .darkAqua : .aqua)
                }
                Toggle("Reduce notch and mascot motion", isOn: $reduceMotion)
                Picker("Open dashboard shortcut", selection: $shortcutPreset) {
                    Text("⌥⌘K").tag("option-command-k")
                    Text("⌥⌘Space").tag("option-command-space")
                    Text("⌃⌥K").tag("control-option-k")
                }
                .onChange(of: shortcutPreset) { _, value in (NSApp.delegate as? KioAppDelegate)?.setShortcutPreset(value) }
                Toggle("Launch at login", isOn: $loginEnabled).onChange(of: loginEnabled) { _, value in setLaunchAtLogin(value) }
            }

            Section("Kio") {
                LabeledContent("Features", value: "Convert · Reel · Cue")
                LabeledContent("Output location", value: outputFolder)
                HStack {
                    Button("Choose output folder…") { chooseOutputFolder() }
                    Button("Restore default") { OutputLocation.restoreDefault(); outputFolder = OutputLocation.preferenceDescription }
                }
            }

            Section("Sessions") {
                Text("Local hooks receive lifecycle status and project metadata. Kio never stores prompts, transcripts or tool arguments.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(SessionProvider.allCases) { provider in
                    HStack {
                        Text(provider.title)
                        Spacer()
                        Text(SessionIntegrationManager.isInstalled(provider) ? "Enabled" : "Off")
                            .font(.caption).foregroundStyle(.secondary)
                        if SessionIntegrationManager.isInstalled(provider) {
                            Button("Remove") { integration(provider, install: false) }
                        } else {
                            Button("Enable") { integration(provider, install: true) }
                        }
                    }
                }
            }

            Section("Clipboard") {
                Toggle("Enable local clipboard history", isOn: $clipboardEnabled)
                Picker("Retention", selection: $retentionDays) {
                    Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
                }
                Picker("Maximum entries", selection: $maximumEntries) {
                    Text("50").tag(50); Text("200").tag(200); Text("500").tag(500)
                }
                .onChange(of: maximumEntries) { _, value in Task { await KioDashboardModel.shared.setClipboardMaximum(value) } }
                TextField("Excluded app bundle IDs", text: $exclusionText, prompt: Text("com.example.password-manager, …"))
                    .onSubmit { saveExclusions() }
                HStack {
                    Button("Save exclusions") { saveExclusions() }
                    Button("Clear history", role: .destructive) { KioDashboardModel.shared.clearClipboard() }
                }
                Text("Clipboard entries stay in local Application Support. macOS concealed and transient pasteboard types are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("News") {
                Toggle("Enable News space", isOn: $newsEnabled)
                Text("RSS and Atom feeds are fetched only when configured. Headlines do not expand the notch unless a topic alert is explicitly enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .padding(18)
        .onAppear {
            NSApp.appearance = switch appearance {
            case "dark": NSAppearance(named: .darkAqua)
            case "light": NSAppearance(named: .aqua)
            default: nil
            }
            excludedBundleIDs = UserDefaults.standard.stringArray(forKey: "kio.clipboard.excludedBundleIDs") ?? []
            exclusionText = excludedBundleIDs.joined(separator: ", ")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            message = "Login setting couldn't be changed: \(error.localizedDescription)"
        }
    }

    private func integration(_ provider: SessionProvider, install: Bool) {
        do {
            if install { try SessionIntegrationManager.install(provider) }
            else { try SessionIntegrationManager.remove(provider) }
            message = "\(provider.title) session hook \(install ? "enabled" : "removed")."
        } catch { message = error.localizedDescription }
    }

    private func saveExclusions() {
        excludedBundleIDs = exclusionText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        UserDefaults.standard.set(excludedBundleIDs, forKey: "kio.clipboard.excludedBundleIDs")
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        if panel.runModal() == .OK, let folder = panel.url {
            do { try OutputLocation.setCustomFolder(folder); outputFolder = OutputLocation.preferenceDescription; message = nil }
            catch { message = error.localizedDescription }
        }
    }
}
