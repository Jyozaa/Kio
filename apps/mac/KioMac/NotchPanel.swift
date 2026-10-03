import AppKit
import Combine
import KioModel
import SwiftUI
import UniformTypeIdentifiers

struct NotchLayout: Equatable {
    let hostWidth: CGFloat
    let hostHeight: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let expandedWidth: CGFloat
    let expandedHeight: CGFloat
    static let empty = NotchLayout(hostWidth: 500, hostHeight: 300, notchWidth: 160, notchHeight: 34,
                                   expandedWidth: 468, expandedHeight: 252)
}

@MainActor
private final class KioNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPanelController: ObservableObject {
    static let shared = NotchPanelController()
    @Published private(set) var isExpanded = false
    @Published private(set) var isAmbient = false
    @Published private(set) var layout = NotchLayout.empty
    private var panel: NSPanel?
    private var display: NSNumber?
    private var collapseTask: Task<Void, Never>?
    private var pointerInside = false
    private var cueSessionActive = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshDisplay() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshDisplay() } })
    }

    func show() {
        if let panel { refreshDisplay(); panel.orderFrontRegardless(); return }
        guard let screen = preferredScreen else { return }
        display = screenNumber(screen)
        updateLayout(screen)
        let panel = KioNotchPanel(contentRect: panelFrame(screen), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = NSHostingView(rootView: NotchContents(controller: self, model: .shared))
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func activateForInput(pinned: Bool = false) {
        _ = pinned
        show()
        collapseTask?.cancel()
        withAnimation(shellAnimation) {
            isAmbient = false
            isExpanded = true
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleForShortcut() {
        if isExpanded { collapse() } else { activateForInput() }
    }

    func pointerChanged(_ inside: Bool) {
        pointerInside = inside
        if inside {
            collapseTask?.cancel(); collapseTask = nil
            if !isAmbient { withAnimation(shellAnimation) { isExpanded = true } }
        } else if isExpanded && !cueSessionActive {
            collapseTask?.cancel()
            collapseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(360))
                guard !Task.isCancelled, let self else { return }
                withAnimation(self.shellAnimation) { self.isExpanded = false }
            }
        }
    }

    func cueSessionChanged(_ active: Bool) {
        cueSessionActive = active
        if active {
            collapseTask?.cancel(); collapseTask = nil
            withAnimation(shellAnimation) { isExpanded = true }
        } else if !pointerInside {
            pointerChanged(false)
        }
    }

    func present(_ event: NotchAmbientEvent?) {
        guard event != nil else {
            withAnimation(shellAnimation) { isAmbient = false }
            return
        }
        guard !isExpanded else { return }
        show()
        collapseTask?.cancel()
        isExpanded = false
        withAnimation(shellAnimation) { isAmbient = true }
    }

    func collapse() {
        collapseTask?.cancel(); collapseTask = nil
        cueSessionActive = false
        withAnimation(shellAnimation) { isExpanded = false; isAmbient = false }
        NotchEventCoordinator.shared.dismiss()
    }

    private var shellAnimation: Animation {
        UserDefaults.standard.bool(forKey: "kio.reduceMotion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.42, dampingFraction: 0.78, blendDuration: 0.1)
    }

    private var preferredScreen: NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func refreshDisplay() {
        guard let panel,
              let screen = display.flatMap({ number in NSScreen.screens.first(where: { screenNumber($0) == number }) }) ?? preferredScreen else { return }
        display = screenNumber(screen); updateLayout(screen)
        panel.setFrame(panelFrame(screen), display: true, animate: false)
    }

    private func updateLayout(_ screen: NSScreen) {
        let notchWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX, right.minX - left.maxX < 360 {
            notchWidth = right.minX - left.maxX
        } else { notchWidth = screen.safeAreaInsets.top > 0 ? 180 : 136 }
        let hostWidth = min(510, max(360, screen.frame.width - 20))
        layout = NotchLayout(hostWidth: hostWidth, hostHeight: 300, notchWidth: min(notchWidth, hostWidth - 20),
            notchHeight: max(34, screen.safeAreaInsets.top), expandedWidth: min(480, hostWidth - 16), expandedHeight: 252)
    }

    private func panelFrame(_ screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.midX - layout.hostWidth / 2, y: screen.frame.maxY - layout.hostHeight,
               width: layout.hostWidth, height: layout.hostHeight)
    }

    private func screenNumber(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }
}

private struct NotchContents: View {
    @ObservedObject var controller: NotchPanelController
    @ObservedObject var model: KioDashboardModel
    @ObservedObject private var eventCoordinator = NotchEventCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isDropTargeted = false
    @State private var mascotAction = 0

    private var reduceMotion: Bool { accessibilityReduceMotion || UserDefaults.standard.bool(forKey: "kio.reduceMotion") }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: controller.isExpanded ? 30 : controller.isAmbient ? 24 : 18,
                                     style: .continuous)
                        .fill(.black)
                        .frame(width: shellWidth, height: shellHeight, alignment: .top)
                        .overlay(alignment: .top) {
                            if controller.isExpanded {
                                dashboard
                                    .padding(.horizontal, 18)
                                    .padding(.top, 16)
                                    .frame(width: controller.layout.expandedWidth, height: controller.layout.expandedHeight,
                                           alignment: .top)
                                    .transition(.opacity.combined(with: .offset(y: -5)))
                                    .transaction { transaction in
                                        transaction.animation = reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.20).delay(0.04)
                                    }
                            } else if controller.isAmbient, let event = eventCoordinator.current {
                                ambient(event)
                                    .frame(width: shellWidth, height: shellHeight)
                                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                                    .transaction { transaction in
                                        transaction.animation = reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.20).delay(0.04)
                                    }
                            } else {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture { controller.activateForInput() }
                            }
                    }
                        .clipped()
                        .shadow(color: .black.opacity(controller.isExpanded ? 0.34 : 0), radius: 18, y: 7)
                        .onHover { controller.pointerChanged($0) }
                    if controller.isExpanded, isDropTargeted {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(.white.opacity(0.34), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                            .frame(width: controller.layout.expandedWidth - 8, height: controller.layout.expandedHeight - 8)
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .onDrop(of: [.fileURL, .url], isTargeted: $isDropTargeted, perform: acceptDrop)
            .onChange(of: eventCoordinator.current) { _, value in
                controller.present(value)
                if value != nil { mascotAction &+= 1 }
            }
            .onChange(of: model.isWorking) { _, working in
                if working { mascotAction &+= 1 }
            }
            .onChange(of: model.attachments.count) { _, count in if count > 0 { mascotAction &+= 1 } }
            .onAppear { controller.present(eventCoordinator.current) }
        }
        .frame(width: controller.layout.hostWidth, height: controller.layout.hostHeight, alignment: .top)
        .background(.clear)
    }

    private var shellWidth: CGFloat {
        controller.isExpanded ? controller.layout.expandedWidth : controller.isAmbient ? 280 : controller.layout.notchWidth
    }
    private var shellHeight: CGFloat {
        controller.isExpanded ? controller.layout.expandedHeight : controller.isAmbient ? 56 : controller.layout.notchHeight
    }

    private var dashboard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(DashboardSpace.allCases) { space in
                    Button { model.select(space) } label: {
                        HStack(spacing: 4) {
                            Label(space.title, systemImage: space.symbol).labelStyle(.titleAndIcon)
                            if let badge = model.badge(for: space) {
                                Text(badge).font(.system(size: 7, weight: .semibold))
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(.white.opacity(0.14), in: Capsule())
                            }
                        }
                        .font(.system(size: 10, weight: model.selectedSpace == space ? .semibold : .medium))
                        .foregroundStyle(model.selectedSpace == space ? .white : .white.opacity(0.50))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(model.selectedSpace == space ? .white.opacity(0.12) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button { controller.collapse() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.55)).help("Close dashboard")
            }
            .frame(height: 26)
            Group {
                switch model.selectedSpace {
                case .kio: KioSpaceView(model: model, onAction: { mascotAction &+= 1 })
                case .sessions: SessionsSpaceView(model: model)
                case .clipboard: ClipboardSpaceView(model: model)
                case .news: NewsSpaceView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.opacity)
        }
        .foregroundStyle(.white.opacity(0.92))
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.22), value: model.selectedSpace)
    }

    private func ambient(_ event: NotchAmbientEvent) -> some View {
        HStack(spacing: 10) {
            KioRibbon(action: mascotAction, reduceMotion: reduceMotion).frame(width: 30, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(event.kind == .sessionNeedsInput ? "Needs input" : "Kio update")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 2)
            Button { model.select(event.kind == .newsAlert ? .news : .sessions); controller.activateForInput() } label: {
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 13)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            let collector = DroppedURLCollector(expected: fileProviders.count) { urls in Task { @MainActor in model.addURLs(urls) } }
            for provider in fileProviders {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in collector.complete(url) }
            }
            if !controller.isExpanded { controller.activateForInput() }
            return true
        }
        if let urlProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            _ = urlProvider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.addMediaURL(url.absoluteString) }
            }
            controller.activateForInput()
            return true
        }
        return false
    }
}

private final class DroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []
    private var remaining: Int
    private let completion: @Sendable ([URL]) -> Void
    init(expected: Int, completion: @escaping @Sendable ([URL]) -> Void) {
        remaining = expected; self.completion = completion
    }
    func complete(_ value: URL?) {
        lock.lock()
        if let value { values.append(value) }
        remaining -= 1
        let done = remaining == 0
        let result = values; lock.unlock()
        if done { completion(result) }
    }
}

struct KioRibbon: View {
    let action: Int
    let reduceMotion: Bool
    @State private var bodyScaleX: CGFloat = 1
    @State private var bodyScaleY: CGFloat = 1
    @State private var bodyRotation = 0.0
    @State private var bodyLift: CGFloat = 0
    @State private var eyeLook: CGFloat = 0
    @State private var motionTask: Task<Void, Never>?
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                ZStack {
                    RibbonSilhouette().fill(Color(red: 0.94, green: 0.90, blue: 0.82))
                    HStack(spacing: size.width * 0.17) {
                        Capsule().fill(.black).frame(width: max(3, size.width * 0.12), height: max(7, size.height * 0.25))
                        Capsule().fill(.black).frame(width: max(3, size.width * 0.12), height: max(7, size.height * 0.25))
                    }
                    .offset(x: eyeLook * size.width * 0.07, y: size.height * 0.02)
                }
                .scaleEffect(x: bodyScaleX, y: bodyScaleY)
                .rotationEffect(.degrees(bodyRotation))
                .offset(y: bodyLift)
            }
            .frame(width: size.width, height: size.height)
            .onAppear { if action > 0 { animateAction() } }
            .onChange(of: action) { _, _ in animateAction() }
            .onDisappear { motionTask?.cancel() }
        }
    }

    private func animateAction() {
        motionTask?.cancel()
        guard !reduceMotion else {
            bodyScaleX = 1; bodyScaleY = 1; bodyRotation = 0; bodyLift = 0; eyeLook = 0
            return
        }
        motionTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.09)) { eyeLook = -1 }
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.13)) {
                bodyScaleX = 1.24; bodyScaleY = 0.76; bodyRotation = 8; bodyLift = -3
            }
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.23, dampingFraction: 0.48)) {
                bodyScaleX = 0.82; bodyScaleY = 1.22; bodyRotation = -5; bodyLift = 2; eyeLook = 0
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                bodyScaleX = 1; bodyScaleY = 1; bodyRotation = 0; bodyLift = 0
            }
        }
    }
}

private struct RibbonSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: 0.18 * w, y: 0.09 * h))
        path.addQuadCurve(to: CGPoint(x: 0.92 * w, y: 0.25 * h), control: CGPoint(x: 0.57 * w, y: -0.05 * h))
        path.addQuadCurve(to: CGPoint(x: 0.82 * w, y: 0.90 * h), control: CGPoint(x: 1.02 * w, y: 0.67 * h))
        path.addQuadCurve(to: CGPoint(x: 0.13 * w, y: 0.81 * h), control: CGPoint(x: 0.46 * w, y: 1.06 * h))
        path.addQuadCurve(to: CGPoint(x: 0.18 * w, y: 0.09 * h), control: CGPoint(x: -0.01 * w, y: 0.31 * h))
        path.closeSubpath()
        return path
    }
}
