import AppKit
import Carbon.HIToolbox
import KioCore
import KioSync
import KioUI
import os
import SwiftUI

@main
struct KioMacApp: App {
    @NSApplicationDelegateAdaptor(KioAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarCommands()
        } label: {
            Image(systemName: "sparkle")
                .accessibilityLabel("Kio")
        }
        .menuBarExtraStyle(.menu)

        Window("Kio", id: "main") {
            KioChatView()
                .frame(minWidth: 620, minHeight: 500)
        }
        .defaultSize(width: 780, height: 650)
        .windowResizability(.contentSize)

        Settings {
            KioSettingsView()
                .frame(width: 590, height: 760)
        }
    }
}

@MainActor
final class KioAppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private let logger = Logger(subsystem: "app.kio.mac", category: "Shortcut")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotchPanelController.shared.show()
        installGlobalShortcut()
        LocalRelayManager.shared.onIncomingRequest = { phoneID, payload, attachmentData in
            KioWorkspace.shared.receiveRemoteRequest(from: phoneID, payload: payload, attachmentData: attachmentData)
        }
        LocalRelayManager.shared.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }

    private func installGlobalShortcut() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), kioHotKeyEvent, 1, &eventType, nil, &hotKeyHandler)
        guard installStatus == noErr else {
            logger.error("Could not install shortcut handler: \(installStatus, privacy: .public)")
            return
        }
        let identifier = EventHotKeyID(signature: OSType(0x4B494F4B), id: 1)
        let registerStatus = RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(optionKey | cmdKey), identifier, GetApplicationEventTarget(), 0, &hotKey)
        if registerStatus == noErr { logger.info("Registered Option-Command-K") }
        else { logger.error("Could not register shortcut: \(registerStatus, privacy: .public)") }
    }
}

private let kioHotKeyEvent: EventHandlerProcPtr = { _, _, _ in
    Task { @MainActor in NotchPanelController.shared.toggleForShortcut() }
    return noErr
}

private struct MenuBarCommands: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Open Kio") { openWindow(id: "main") }
        Button("Show notch") { NotchPanelController.shared.setExpanded(true, pinned: true) }
        Divider()
        Button("Settings…") { openSettings() }
        Button("Quit Kio") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
