import AppKit
import Carbon.HIToolbox
import KioCore
import KioSync
import KioTools
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
final class KioAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
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
        showFirstRunIfNeeded()
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
            let installStatus = InstallEventHandler(GetApplicationEventTarget(), kioHotKeyEvent, 1, &eventType, nil, &hotKeyHandler)
            guard installStatus == noErr else {
                logger.error("Could not install shortcut handler: \(installStatus, privacy: .public)")
                return
            }
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
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
        if registerStatus == noErr { logger.info("Registered global Kio shortcut: \(preset, privacy: .public)") }
        else { logger.error("Could not register shortcut: \(registerStatus, privacy: .public)") }
    }

    func setShortcutPreset(_ preset: String) {
        guard ["option-command-k", "option-command-space", "control-option-k"].contains(preset) else { return }
        UserDefaults.standard.set(preset, forKey: "kio.shortcutPreset")
        installGlobalShortcut()
    }

    private func showFirstRunIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "kio.hasCompletedOnboarding") else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Kio"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: KioOnboardingView(onFinish: { [weak self, weak window] in
            UserDefaults.standard.set(true, forKey: "kio.hasCompletedOnboarding")
            window?.close()
            self?.onboardingWindow = nil
        }, onOpenSettings: { [weak self, weak window] in
            UserDefaults.standard.set(true, forKey: "kio.hasCompletedOnboarding")
            window?.close()
            self?.onboardingWindow = nil
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }))
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === onboardingWindow else { return }
        UserDefaults.standard.set(true, forKey: "kio.hasCompletedOnboarding")
        onboardingWindow = nil
    }

    private var onboardingWindow: NSWindow?
}

private struct KioOnboardingView: View {
    let onFinish: () -> Void
    let onOpenSettings: () -> Void
    @State private var page = 0

    private let titles = ["Meet Kio", "Private by default", "Use the notch", "Phone pairing is optional"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach(titles.indices, id: \.self) { index in
                    Capsule().fill(index == page ? Color(hex: AgentID.kio.colorHex) : Color.secondary.opacity(0.2))
                        .frame(width: index == page ? 25 : 7, height: 7)
                }
                Spacer()
                Button("Skip") { onFinish() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.bottom, 24)

            Group {
                switch page {
                case 0:
                    VStack(spacing: 15) {
                        AgentBlob(.kio, size: 76)
                        Text("A small assistant, right at your MacBook notch.").font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                case 1:
                    VStack(spacing: 14) {
                        Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(Color(hex: AgentID.pip.colorHex))
                        Text("Your files stay on this Mac.").font(.system(size: 16, weight: .medium))
                        Text("Kio uses registered native tools. An optional local model can plan broader requests; its 1.72 GB download is separate and runs on this Mac.").font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 370)
                    }
                case 2:
                    VStack(spacing: 14) {
                        AgentBlob(.clerk, mood: .curious, size: 58)
                        Text("Hover, click, or press ⌥⌘K to open Kio.").font(.system(size: 15, weight: .medium))
                        Text("Type a request, press Return, or drag files onto the notch. The full window keeps your history and detailed results.").font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 370)
                    }
                default:
                    VStack(spacing: 14) {
                        HStack(spacing: -4) { AgentBlob(.kio, size: 40); AgentBlob(.courier, size: 40) }
                        Text("Take Kio to a browser when you want.").font(.system(size: 15, weight: .medium))
                        Text("Pairing is optional. Open Kio Settings whenever you want to connect a browser or phone; the Mac works without a relay or account.").font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 370)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.16), value: page)

            HStack {
                if page > 0 { Button("Back") { page -= 1 }.buttonStyle(.plain) }
                Spacer()
                if page == titles.count - 1 {
                    Button("Pair a device later in Settings") { onOpenSettings() }.buttonStyle(.plain)
                    Button("Finish") { onFinish() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { page += 1 }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 20)
        }
        .padding(26)
        .frame(width: 500, height: 420)
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
        Button("Show notch") { NotchPanelController.shared.activateForInput() }
        Divider()
        Button("Settings…") { openSettings() }
        Button("Quit Kio") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
