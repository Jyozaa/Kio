import AppKit
import Carbon.HIToolbox
import KioTools
import SwiftUI

@main
struct KioMacApp: App {
    @NSApplicationDelegateAdaptor(KioAppDelegate.self) private var appDelegate
    var body: some Scene {
        MenuBarExtra {
            Button("Open notch dashboard") { NotchPanelController.shared.activateForInput() }
                .keyboardShortcut("k", modifiers: [.command, .option])
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit Kio") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 18, height: 18)
                .accessibilityLabel("Kio")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            KioSettingsView().frame(width: 570, height: 650)
        }
    }
}

@MainActor
final class KioAppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotchPanelController.shared.show()
        installGlobalShortcut()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        OutputLocation.stopAccessingSelectedFolder()
    }

    private func installGlobalShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if hotKeyHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), kioHotKeyEvent, 1, &eventType, nil, &hotKeyHandler)
            guard status == noErr else { return }
        }
        let preset = UserDefaults.standard.string(forKey: "kio.shortcutPreset") ?? "option-command-k"
        let keyCode: UInt32
        let modifiers: UInt32
        switch preset {
        case "option-command-space": keyCode = UInt32(kVK_Space); modifiers = UInt32(optionKey | cmdKey)
        case "control-option-k": keyCode = UInt32(kVK_ANSI_K); modifiers = UInt32(controlKey | optionKey)
        default: keyCode = UInt32(kVK_ANSI_K); modifiers = UInt32(optionKey | cmdKey)
        }
        let identifier = EventHotKeyID(signature: OSType(0x4B494F4B), id: 1)
        _ = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
    }

    func setShortcutPreset(_ preset: String) {
        guard ["option-command-k", "option-command-space", "control-option-k"].contains(preset) else { return }
        UserDefaults.standard.set(preset, forKey: "kio.shortcutPreset")
        installGlobalShortcut()
    }
}

private let kioHotKeyEvent: EventHandlerProcPtr = { _, _, _ in
    Task { @MainActor in NotchPanelController.shared.toggleForShortcut() }
    return noErr
}
