import AppKit
import Combine
import KioCore
import KioUI
import os
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NotchPanelController: ObservableObject {
    static let shared = NotchPanelController()

    private var panel: NSPanel?
    private var anchoredScreen: NSScreen?
    @Published private(set) var isExpanded = false
    private(set) var isPinned = false
    private var collapseTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "app.kio.mac", category: "Notch")

    private init() {}

    func show() {
        guard panel == nil else { panel?.orderFrontRegardless(); return }
        anchoredScreen = Self.preferredScreen()
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: NotchContents(workspace: .shared, controller: self))
        self.panel = panel
        updateFrame(animated: false)
        panel.orderFrontRegardless()
    }

    func setExpanded(_ expanded: Bool, pinned: Bool = false) {
        collapseTask?.cancel()
        logger.debug("Panel expansion request: \(expanded, privacy: .public)")
        if expanded {
            isExpanded = true
            if pinned { isPinned = true }
        } else {
            guard !isPinned else { return }
            isExpanded = false
        }
        updateFrame(animated: true)
    }

    func pinForComposition() { setExpanded(true, pinned: true) }
    func unpinComposition() { isPinned = false }

    func scheduleCollapse(after delay: Duration = .milliseconds(260)) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !self.isPinned else { return }
            if KioWorkspace.shared.isWorking {
                self.scheduleCollapse(after: .seconds(3))
                return
            }
            self.setExpanded(false)
        }
    }

    func activateForInput() {
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pinForComposition()
    }

    func toggleForShortcut() {
        if isExpanded { collapse() }
        else { activateForInput() }
    }

    func collapse() {
        isPinned = false
        setExpanded(false)
    }

    private func updateFrame(animated: Bool) {
        guard let panel else { return }
        if anchoredScreen == nil { anchoredScreen = Self.preferredScreen() }
        guard let screen = anchoredScreen ?? NSScreen.main else { return }
        let geometry = Self.geometry(for: screen)
        let width = isExpanded ? min(440, screen.frame.width - 32) : geometry.notchWidth
        let height: CGFloat = isExpanded ? 140 : max(34, geometry.notchHeight)
        let frame = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height,
                           width: width, height: height)
        panel.setFrame(frame, display: true, animate: animated)
    }

    private static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    static func geometry(for screen: NSScreen) -> (notchWidth: CGFloat, notchHeight: CGFloat) {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let measured = right.minX - left.maxX
            if screen.safeAreaInsets.top > 0, measured > 0, measured < 360 {
                return (measured, max(32, screen.safeAreaInsets.top))
            }
        }
        if screen.safeAreaInsets.top > 0 { return (180, max(32, screen.safeAreaInsets.top)) }
        return (136, 34)
    }
}

private struct NotchContents: View {
    @ObservedObject var workspace: KioWorkspace
    @ObservedObject var controller: NotchPanelController
    @State private var isTargeted = false
    @State private var isHovering = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var command = ""
    @FocusState private var commandFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("kio.hoverExpansion") private var hoverExpansion = true

    var body: some View {
        ZStack(alignment: .top) {
            NotchSilhouette(topWidth: controller.isExpanded ? Self.topWidth : nil,
                            radius: controller.isExpanded ? 22 : 17)
                .fill(Color.black)
                .overlay {
                    NotchSilhouette(topWidth: controller.isExpanded ? Self.topWidth : nil,
                                    radius: controller.isExpanded ? 22 : 17)
                        .stroke(isTargeted ? Color(hex: AgentID.pixel.colorHex) : .clear, lineWidth: 1.5)
                }
            if controller.isExpanded {
                expandedContents
                    .padding(.horizontal, 18)
                    .padding(.top, 21)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                AgentBlob(.kio, size: 24)
                    .offset(y: 4)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.84), value: controller.isExpanded)
        .contentShape(NotchSilhouette(topWidth: controller.isExpanded ? Self.topWidth : nil, radius: 17))
        .onHover { inside in
            if inside {
                guard hoverExpansion else { return }
                isHovering = true
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, isHovering else { return }
                    controller.setExpanded(true)
                }
            } else {
                isHovering = false
                hoverTask?.cancel()
                controller.scheduleCollapse()
            }
        }
        .onChange(of: isTargeted) { _, targeted in
            if targeted { controller.setExpanded(true) }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted, perform: acceptDrop)
        .onExitCommand { controller.collapse() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var expandedContents: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                AgentBlob(workspace.isWorking ? .pip : .kio, mood: workspace.isWorking ? .working : (isTargeted ? .curious : .idle), size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.isWorking ? "Kio is working" : (isTargeted ? "Drop to add files" : "Kio"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(workspace.attachments.isEmpty ? "Local files stay on this Mac" : workspace.attachments.map(\.displayName).joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    if workspace.isWorking {
                        workspace.cancelCurrentTask()
                    } else {
                        controller.activateForInput()
                        commandFocused = true
                    }
                } label: {
                    Image(systemName: workspace.isWorking ? "stop.fill" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(workspace.isWorking ? Color.white : Color.black)
                        .frame(width: 27, height: 27)
                        .background(workspace.isWorking ? Color.white.opacity(0.18) : Color(hex: AgentID.kio.colorHex), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!workspace.isWorking && command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 8) {
                TextField(workspace.activeOutput == nil ? "What should I do with these?" : "Ask a follow-up…", text: $command, axis: .vertical)
                    .font(.system(size: 12))
                    .lineLimit(1...2)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .focused($commandFocused)
                    .onSubmit { sendCommand() }
                    .onTapGesture { controller.activateForInput() }
                if !workspace.attachments.isEmpty {
                    Button { workspace.clearAttachments() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.white.opacity(0.5))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sendCommand() {
        let value = command
        command = ""
        controller.pinForComposition()
        workspace.submit(value)
        commandFocused = false
        controller.unpinComposition()
        controller.scheduleCollapse(after: .seconds(4))
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        controller.pinForComposition()
        let collector = URLCollector()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let url = item as? URL { collector.add(url) }
                else if let url = item as? NSURL { collector.add(url as URL) }
                else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { collector.add(url) }
            }
        }
        group.notify(queue: .main) {
            workspace.addURLs(collector.values)
            controller.setExpanded(true, pinned: true)
        }
        return true
    }

    private static var topWidth: CGFloat {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else { return 180 }
        return NotchPanelController.geometry(for: screen).notchWidth
    }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func add(_ value: URL) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}

private struct NotchSilhouette: Shape {
    let topWidth: CGFloat?
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = min(rect.width, max(90, topWidth ?? rect.width - 22))
        let center = rect.midX
        let left = center - top / 2
        let right = center + top / 2
        let shoulder = min(24, rect.height * 0.22)
        let r = min(radius, rect.width / 4, rect.height / 3)
        var path = Path()
        path.move(to: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + shoulder),
                      control1: CGPoint(x: right + shoulder * 0.45, y: rect.minY),
                      control2: CGPoint(x: rect.maxX, y: rect.minY + shoulder * 0.25))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + shoulder))
        path.addCurve(to: CGPoint(x: left, y: rect.minY),
                      control1: CGPoint(x: rect.minX, y: rect.minY + shoulder * 0.25),
                      control2: CGPoint(x: left - shoulder * 0.45, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
