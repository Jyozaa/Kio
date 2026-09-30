import AppKit
import CompanionCore
import CoreGraphics
import SwiftUI

@MainActor
final class NotchOverlayController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var rootView = AnyView(EmptyView())
    private var requestedWidth: CGFloat = 48
    private var requestedHeight: CGFloat = 48
    private var screenObserver: NSObjectProtocol?

    var isVisible: Bool { panel?.isVisible == true }

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition(animated: false) }
        }
    }

    func show(rootView: AnyView, width: CGFloat = 48, height: CGFloat = 48) {
        self.rootView = rootView
        requestedWidth = width
        requestedHeight = height
        let panel = panel ?? makePanel()
        self.panel = panel
        let host = hostingView ?? NSHostingView(rootView: rootView)
        hostingView = host
        host.rootView = rootView
        panel.contentView = host
        let finalFrame = frame(for: selectedScreen())
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrame(
                NSRect(
                    x: finalFrame.minX,
                    y: finalFrame.maxY - 12,
                    width: finalFrame.width,
                    height: 12
                ),
                display: false
            )
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func update(rootView: AnyView, width: CGFloat, height: CGFloat) {
        guard let panel, panel.isVisible else { return }
        self.rootView = rootView
        let sizeChanged = requestedWidth != width || requestedHeight != height
        requestedWidth = width
        requestedHeight = height
        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let host = NSHostingView(rootView: rootView)
            hostingView = host
            panel.contentView = host
        }
        if sizeChanged { reposition(animated: true) }
    }

    func hide(animated: Bool = true) {
        guard let panel, panel.isVisible else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
                panel.animator().setFrame(
                    NSRect(x: panel.frame.minX, y: panel.frame.maxY - 8, width: panel.frame.width, height: 8),
                    display: true
                )
            } completionHandler: { [weak panel] in
                Task { @MainActor in panel?.orderOut(nil) }
            }
        } else {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: requestedWidth, height: requestedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        return panel
    }

    private func selectedScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        let pointerScreen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
        return frontmostWindowScreen() ?? pointerScreen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func frontmostWindowScreen() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == pid {
            guard let raw = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  !bounds.isEmpty else { continue }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return screen
            }
        }
        return nil
    }

    private func frame(for screen: NSScreen?) -> NSRect {
        guard let screen else {
            return NSRect(x: 0, y: 0, width: requestedWidth, height: requestedHeight)
        }
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        let geometry = OverlayScreenGeometry(
            x: screen.frame.minX,
            y: screen.frame.minY,
            width: screen.frame.width,
            height: screen.frame.height,
            visibleTop: screen.visibleFrame.maxY,
            safeTop: screen.safeAreaInsets.top,
            hasNotch: screen.safeAreaInsets.top > 0 && left != nil && right != nil
        )
        let layout = geometry.overlayFrame(width: requestedWidth, height: requestedHeight)
        return NSRect(x: layout.x, y: layout.y, width: layout.width, height: layout.height)
    }

    private func reposition(animated: Bool) {
        guard let panel, panel.isVisible else { return }
        let target = frame(for: selectedScreen())
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }
}
