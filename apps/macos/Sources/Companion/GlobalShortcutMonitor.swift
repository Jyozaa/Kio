import AppKit
import CoreGraphics
import CompanionCore
import Foundation

extension Notification.Name {
    static let kioEscapeObserved = Notification.Name("KioEscapeObserved")
}

private final class ModifierEventTap: @unchecked Sendable {
    private let lock = NSLock()
    private var recognizer = ModifierChordRecognizer()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onTrigger: (@Sendable () -> Void)?
    var onTapDisabled: (@Sendable () -> Void)?
    var onEvent: (@Sendable () -> Void)?

    var isCreated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tap != nil
    }

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: modifierTapCallback,
            userInfo: context
        ) else { return false }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            return false
        }
        tap = eventTap
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func stop() {
        lock.lock()
        recognizer.reset()
        lock.unlock()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    fileprivate func receive(type: CGEventType, event: CGEvent?) {
        var shouldTrigger = false
        var wasDisabled = false
        let observedEvent = type == .flagsChanged || type == .keyDown
        lock.lock()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            recognizer.reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            wasDisabled = true
        case .flagsChanged:
            guard let event else {
                lock.unlock()
                return
            }
            let flags = event.flags
            shouldTrigger = recognizer.modifiersChanged(
                optionDown: flags.contains(.maskAlternate),
                commandDown: flags.contains(.maskCommand)
            )
        case .keyDown:
            guard let event else {
                lock.unlock()
                return
            }
            recognizer.nonModifierKeyDown()
            // The listen-only tap observes only the Escape key code; it never
            // consumes or records ordinary keyboard input.
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                shouldTrigger = false
                NotificationCenter.default.post(name: .kioEscapeObserved, object: nil)
            }
        default:
            break
        }
        lock.unlock()
        if observedEvent { onEvent?() }
        if wasDisabled { onTapDisabled?() }
        if shouldTrigger { onTrigger?() }
    }
}

private let modifierTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<ModifierEventTap>.fromOpaque(userInfo).takeUnretainedValue()
    monitor.receive(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

@MainActor
final class GlobalShortcutMonitor: ObservableObject {
    static let shared = GlobalShortcutMonitor()

    @Published private(set) var status = "The global shortcut is required for normal Kio setup."
    @Published private(set) var permissionGranted = false
    @Published private(set) var isEnabled = false
    @Published private(set) var eventTapCreated = false
    @Published private(set) var eventTapHealthy = false
    @Published private(set) var lastEventAt: Date?
    @Published private(set) var recoveryCount = 0
    private let eventTap = ModifierEventTap()
    private var trigger: (() -> Void)?
    private var activationObserver: NSObjectProtocol?

    init() {
        refreshPermission()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPermission() }
        }
    }

    func configure(onTrigger: @escaping () -> Void) {
        trigger = onTrigger
        eventTap.onTrigger = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.trigger?() }
        }
        eventTap.onTapDisabled = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.recoveryCount += 1
                self.eventTapCreated = self.eventTap.isCreated
                self.eventTapHealthy = self.eventTap.isCreated && self.isEnabled
                self.status = "Global shortcut event tap recovered after macOS disabled it."
            }
        }
        eventTap.onEvent = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastEventAt = Date()
                self.eventTapHealthy = self.eventTap.isCreated && self.isEnabled
            }
        }
        if CGPreflightListenEventAccess() { start() }
    }

    func stop() {
        eventTap.stop()
        isEnabled = false
        eventTapCreated = false
        eventTapHealthy = false
    }

    func requestPermission() {
        let granted = CGRequestListenEventAccess()
        if granted || CGPreflightListenEventAccess() {
            permissionGranted = true
            start()
        } else {
            status = "macOS hasn't granted Input Monitoring to this Kio build. Enable the running Kio app, then return here or restart Kio."
            openPrivacyPane("Privacy_ListenEvent")
        }
    }

    func refreshPermission() {
        if CGPreflightListenEventAccess() {
            permissionGranted = true
            if trigger != nil { start() }
            else { status = "Global Shortcut permission is enabled and will start with Kio." }
        } else {
            eventTap.stop()
            permissionGranted = false
            isEnabled = false
            status = "Global Shortcut permission is required for normal Kio setup."
        }
    }

    private func start() {
        guard CGPreflightListenEventAccess() else {
            eventTap.stop()
            permissionGranted = false
            isEnabled = false
            eventTapCreated = false
            eventTapHealthy = false
            status = "Global Shortcut permission is required for normal Kio setup."
            return
        }
        permissionGranted = true
        isEnabled = eventTap.start()
        eventTapCreated = eventTap.isCreated
        eventTapHealthy = isEnabled && eventTapCreated
        status = isEnabled
            ? "Global Option+Command shortcut is enabled."
            : "Could not start the global shortcut. Restart Kio and check its permission."
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
