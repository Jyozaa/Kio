import AppKit
import Combine
import KioCore
import KioUI
import os
import SwiftUI
import UniformTypeIdentifiers

struct NotchLayout: Equatable {
    let hostWidth: CGFloat
    let hostHeight: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let screenTopInset: CGFloat
    let expandedWidth: CGFloat
    let expandedHeight: CGFloat

    static let empty = NotchLayout(hostWidth: 440, hostHeight: 250, notchWidth: 180, notchHeight: 36,
                                   screenTopInset: 0, expandedWidth: 420, expandedHeight: 200)
}

@MainActor
private final class KioNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPanelController: ObservableObject {
    static let shared = NotchPanelController()

    private var panel: NSPanel?
    private var screenNumber: NSNumber?
    private var interaction = NotchInteractionState()
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var screenObservers: [NSObjectProtocol] = []
    @Published private(set) var isExpanded = false
    @Published private(set) var focusCommandRequest = 0
    @Published private(set) var layout = NotchLayout.empty
    private let logger = Logger(subsystem: "app.kio.mac", category: "Notch")

    private init() {
        let displayToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshDisplay() }
        }
        let wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshDisplay() }
        }
        screenObservers = [displayToken, wakeToken]
    }

    func show() {
        if let panel {
            refreshDisplay()
            panel.orderFrontRegardless()
            return
        }
        guard let screen = Self.preferredScreen() else { return }
        screenNumber = Self.number(for: screen)
        updateLayout(for: screen)
        let frame = Self.panelFrame(for: screen, layout: layout)
        let panel = KioNotchPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = NSHostingView(rootView: NotchContents(workspace: .shared, controller: self))
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func pointerChanged(_ inside: Bool, hoverExpansion: Bool, dwellMilliseconds: Int) {
        interaction.set(.pointer, active: inside)
        if inside {
            collapseTask?.cancel()
            collapseTask = nil
            guard hoverExpansion, !isExpanded else { return }
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(max(0, min(500, dwellMilliseconds))))
                guard !Task.isCancelled, let self, self.interaction.isActive(.pointer) else { return }
                self.setExpanded(true)
            }
        } else {
            hoverTask?.cancel()
            scheduleCollapse()
        }
    }

    func inputFocusChanged(_ focused: Bool) {
        interaction.set(.inputFocus, active: focused)
        if focused {
            cancelCollapse()
            setExpanded(true)
        } else {
            scheduleCollapse()
        }
    }

    func composingChanged(_ composing: Bool) {
        interaction.set(.composing, active: composing)
        if !composing { scheduleCollapse() }
    }

    func attachmentsChanged(_ hasAttachments: Bool) {
        interaction.set(.attachments, active: hasAttachments)
        if !hasAttachments { scheduleCollapse() }
    }

    func draggingChanged(_ dragging: Bool) {
        interaction.set(.dragging, active: dragging)
        if dragging {
            cancelCollapse()
            setExpanded(true)
        } else {
            scheduleCollapse()
        }
    }

    func workingChanged(_ working: Bool) {
        interaction.set(.working, active: working)
        if !working { scheduleCollapse(after: .milliseconds(700)) }
    }

    func resultInteractionChanged(_ active: Bool) {
        interaction.set(.resultInteraction, active: active)
        if active {
            cancelCollapse()
            setExpanded(true)
        } else {
            scheduleCollapse()
        }
    }

    func activateForInput() {
        show()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setExpanded(true)
        focusCommandRequest &+= 1
    }

    func toggleForShortcut() {
        if isExpanded {
            guard !KioWorkspace.shared.isWorking else { return }
            setExpanded(false, force: true)
        } else {
            activateForInput()
        }
    }

    func collapse() {
        guard !KioWorkspace.shared.isWorking else { return }
        interaction.set(.inputFocus, active: false)
        interaction.set(.composing, active: false)
        interaction.set(.pointer, active: false)
        interaction.set(.attachments, active: false)
        interaction.set(.dragging, active: false)
        interaction.set(.resultInteraction, active: false)
        setExpanded(false, force: true)
    }

    func setExpanded(_ expanded: Bool, force: Bool = false) {
        cancelCollapse()
        logger.debug("Panel expansion request: \(expanded, privacy: .public)")
        if expanded {
            guard !isExpanded else { return }
            isExpanded = true
        } else {
            guard force || !shouldRemainExpandedAutomatically else { return }
            guard isExpanded else { return }
            isExpanded = false
        }
    }

    private var shouldRemainExpandedAutomatically: Bool {
        interaction.isActive(.pointer) || interaction.isActive(.dragging)
    }

    private func scheduleCollapse(after delay: Duration = .milliseconds(340)) {
        cancelCollapse()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.shouldRemainExpandedAutomatically else { return }
            self.setExpanded(false, force: true)
        }
    }

    private func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    private func refreshDisplay() {
        guard panel != nil else { return }
        let screen = screenNumber.flatMap { current in
            NSScreen.screens.first(where: { Self.number(for: $0) == current })
        } ?? Self.preferredScreen()
        guard let screen else { return }
        screenNumber = Self.number(for: screen)
        updateLayout(for: screen)
        panel?.setFrame(Self.panelFrame(for: screen, layout: layout), display: true, animate: false)
    }

    private func updateLayout(for screen: NSScreen) {
        let geometry = Self.geometry(for: screen)
        let hostWidth = max(180, min(500, screen.frame.width - 24))
        let hostHeight = max(220, min(280, screen.frame.height - 24))
        layout = NotchLayout(hostWidth: hostWidth, hostHeight: hostHeight,
                             notchWidth: min(geometry.notchWidth, hostWidth - 20),
                             notchHeight: max(34, geometry.notchHeight),
                             screenTopInset: max(0, screen.safeAreaInsets.top),
                             expandedWidth: min(444, hostWidth - 12),
                             expandedHeight: min(200, hostHeight - 8))
    }

    private static func panelFrame(for screen: NSScreen, layout: NotchLayout) -> CGRect {
        CGRect(x: screen.frame.midX - layout.hostWidth / 2,
               y: screen.frame.maxY - layout.hostHeight,
               width: layout.hostWidth, height: layout.hostHeight)
    }

    private static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func number(for screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
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
    @State private var command = ""
    @State private var editingCompletion = false
    @State private var completionReturnedToComposer = false
    @State private var stageMascotAgent: AgentID = .kio
    @State private var coordinatorHasDeparted = false
    @State private var agentHasArrived = false
    @State private var launchSmokeVisible = false
    @FocusState private var commandFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("kio.hoverExpansion") private var hoverExpansion = true
    @AppStorage("kio.hoverDwellMilliseconds") private var hoverDwellMilliseconds = 150

    private var latestResponse: String? {
        workspace.conversation.last(where: { $0.speaker != "You" && $0.speaker != "Phone" })?.message
    }

    private var inputPrompt: String {
        if workspace.attachments.isEmpty { return "Ask Kio or drop files" }
        return "Add a note for these files"
    }

    private var displayAgent: AgentID {
        guard let state = workspace.executionState else { return .kio }
        if (state.status == .planning || (state.status == .running && state.currentStepIndex == nil)),
           let owner = state.plan?.steps.first?.owner { return owner }
        return state.activeAgent
    }

    private var targetMascotAgent: AgentID {
        guard workspace.executionState != nil, workspace.isWorking || hasTerminalResult else { return .kio }
        return displayAgent
    }

    private var characterMood: CharacterMood {
        switch workspace.executionState?.status {
        case .planning: .thinking
        case .running: .working
        case .completed: .success
        case .waitingForUser, .failed: .failure
        case .cancelled, .none: .idle
        }
    }

    private var hasTerminalResult: Bool {
        switch workspace.executionState?.status {
        case .completed, .waitingForUser, .failed, .cancelled: true
        case .planning, .running, .none: false
        }
    }

    private var completionTaskKey: String {
        let status = workspace.executionState.map { String(describing: $0.status) } ?? "none"
        return "\(status):\(workspace.isWorking)"
    }

    private var terminalTitle: String {
        switch workspace.executionState?.status {
        case .completed: "DONE"
        case .failed: "COULDN’T FINISH"
        case .waitingForUser: "NEEDS YOUR INPUT"
        case .cancelled: "STOPPED"
        case .planning, .running, .none: "RESPONSE"
        }
    }

    private var terminalMessage: String {
        workspace.executionState?.failureMessage ?? latestResponse ?? workspace.executionState?.statusText ?? "Done."
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchSilhouette(progress: controller.isExpanded ? 1 : 0, layout: controller.layout)
                .fill(Color.black)
                .overlay {
                    NotchSilhouette(progress: controller.isExpanded ? 1 : 0, layout: controller.layout)
                        .stroke(isTargeted ? Color(hex: AgentID.pixel.colorHex) : .clear, lineWidth: 1.5)
                }
            if controller.isExpanded {
                expandedContents
                    .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
            } else {
                AgentBlob(agentHasArrived ? stageMascotAgent : .kio, size: 24)
                    .frame(width: controller.layout.notchWidth + 16, height: controller.layout.notchHeight + 12)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.activateForInput() }
            }
        }
        .frame(width: controller.layout.hostWidth, height: controller.layout.hostHeight, alignment: .top)
        .preferredColorScheme(.dark)
        .contentShape(NotchInteractionRegion(progress: controller.isExpanded ? 1 : 0, layout: controller.layout))
        .onHover { controller.pointerChanged($0, hoverExpansion: hoverExpansion, dwellMilliseconds: hoverDwellMilliseconds) }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted, perform: acceptDrop)
        .onChange(of: isTargeted) { _, value in controller.draggingChanged(value) }
        .onChange(of: commandFocused) { _, value in controller.inputFocusChanged(value) }
        .onChange(of: command) { _, value in controller.composingChanged(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        .onChange(of: workspace.attachments.count) { _, value in controller.attachmentsChanged(value > 0) }
        .onChange(of: workspace.isWorking) { _, value in controller.workingChanged(value) }
        .task(id: completionTaskKey) {
            switch workspace.executionState?.status {
            case .completed, .failed, .waitingForUser, .cancelled:
                completionReturnedToComposer = false
                try? await Task.sleep(for: .milliseconds(1900))
                guard !Task.isCancelled else { return }
                completionReturnedToComposer = true
            case .planning, .running, .none:
                completionReturnedToComposer = false
            }
        }
        .task(id: targetMascotAgent) {
            let target = targetMascotAgent
            guard target != stageMascotAgent else { return }

            guard controller.isExpanded else {
                stageMascotAgent = target
                coordinatorHasDeparted = target != .kio
                agentHasArrived = target != .kio
                launchSmokeVisible = false
                return
            }

            if target == .kio {
                launchSmokeVisible = false
                withAnimation(.spring(response: 0.78, dampingFraction: 0.76)) {
                    stageMascotAgent = .kio
                    coordinatorHasDeparted = false
                    agentHasArrived = false
                }
                return
            }

            if stageMascotAgent == .kio {
                launchSmokeVisible = true
                withAnimation(.easeInOut(duration: 1.35)) { coordinatorHasDeparted = true }
                try? await Task.sleep(for: .milliseconds(430))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.72, dampingFraction: 0.76)) {
                    stageMascotAgent = target
                    agentHasArrived = true
                }
                try? await Task.sleep(for: .milliseconds(1400))
                guard !Task.isCancelled else { return }
                launchSmokeVisible = false
            } else {
                launchSmokeVisible = false
                withAnimation(.spring(response: 0.72, dampingFraction: 0.76)) {
                    stageMascotAgent = target
                    agentHasArrived = true
                }
            }
        }
        .onChange(of: controller.focusCommandRequest) { _, _ in
            editingCompletion = true
            commandFocused = true
        }
        .onExitCommand { controller.collapse() }
        .animation(reduceMotion ? .easeInOut(duration: 0.14) : .spring(response: 0.42, dampingFraction: 0.9), value: controller.isExpanded)
        .accessibilityElement(children: .contain)
    }

    private var expandedContents: some View {
        let topInset = max(42, controller.layout.screenTopInset + 8)
        let mascotWidth = controller.layout.expandedWidth * 0.31
        let contentHeight = max(90, controller.layout.expandedHeight - topInset - 10)
        return HStack(spacing: 12) {
            mascotStage
                .frame(width: mascotWidth, height: contentHeight)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text(panelTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    historyButton
                    Button { controller.collapse() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.68))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Collapse Kio")
                }
                if workspace.isWorking {
                    workingPanel
                } else if hasTerminalResult && !editingCompletion && !completionReturnedToComposer {
                    completionPanel
                } else {
                    composer
                }
                if !workspace.attachments.isEmpty && !hasTerminalResult {
                    Text(workspace.attachments.map(\.displayName).joined(separator: " · "))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .padding(.leading, 5)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 16)
        .padding(.top, topInset)
        .padding(.bottom, 10)
        .frame(width: controller.layout.expandedWidth, height: controller.layout.expandedHeight, alignment: .top)
    }

    private var panelTitle: String {
        if workspace.isWorking { return "\(displayAgent.name) is working" }
        if !workspace.attachments.isEmpty { return "\(workspace.attachments.count) file\(workspace.attachments.count == 1 ? "" : "s") ready" }
        return "Ready when you are"
    }

    private var mascotStage: some View {
        ZStack {
            AgentBlob(.kio, mood: baseMascotMood, size: 66)
                .offset(y: coordinatorHasDeparted ? -250 : 0)
                .zIndex(coordinatorHasDeparted ? 0 : 1)
            if launchSmokeVisible {
                LaunchSmoke()
                    .offset(y: 28)
                    .zIndex(1)
            }
            if agentHasArrived {
                AgentBlob(stageMascotAgent, mood: characterMood, size: 58)
                    .id(stageMascotAgent)
                    .zIndex(2)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
                LandingBurst()
                    .id(stageMascotAgent)
                    .offset(y: 34)
                    .zIndex(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var baseMascotMood: CharacterMood {
        if workspace.isWorking { return .working }
        if hasTerminalResult && displayAgent == .kio { return characterMood }
        return .idle
    }

    private var historyButton: some View {
        Button { openWindow(id: "main") } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 26, height: 24)
                .background(Color.white.opacity(0.09), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open chat history")
        .help("History")
    }

    private var composer: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isTargeted ? Color(hex: AgentID.pixel.colorHex) : Color.white.opacity(0.55))
                .accessibilityHidden(true)
            TextField("", text: $command, prompt: Text(inputPrompt).foregroundColor(.white.opacity(0.58)), axis: .vertical)
                .font(.system(size: 12))
                .lineLimit(1...2)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .focused($commandFocused)
                .submitLabel(.send)
                .onSubmit { sendCommand() }
                .accessibilityLabel("Message Kio or drop files")
            Button { sendCommand() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 28, height: 28)
                    .background(Color(hex: AgentID.kio.colorHex), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 54)
        .background(isTargeted ? Color(hex: AgentID.pixel.colorHex).opacity(0.14) : Color.white.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(isTargeted ? Color(hex: AgentID.pixel.colorHex) : Color.white.opacity(0.12),
                        style: StrokeStyle(lineWidth: 1, dash: isTargeted ? [6, 4] : []))
        }
    }

    private var workingPanel: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(workspace.executionState?.statusText ?? "Working on it…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                if !workspace.attachments.isEmpty {
                    Text("\(workspace.attachments.count) file\(workspace.attachments.count == 1 ? "" : "s") in use")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.52))
                }
            }
            Spacer(minLength: 0)
            Button { workspace.cancelCurrentTask() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop task")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
    }

    private var completionPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(terminalTitle)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(hex: displayAgent.colorHex))
                Spacer(minLength: 4)
                if let artifact = workspace.activeOutput, artifact.refreshedFromDisk() != nil {
                    Button("Open") { NSWorkspace.shared.open(artifact.fileURL) }
                        .font(.system(size: 9, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color(hex: AgentID.kio.colorHex))
                }
                Button { beginNewRequest() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.74))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New request")
            }
            Text(terminalMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
    }

    private func sendCommand() {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !workspace.isWorking else { return }
        command = ""
        editingCompletion = false
        commandFocused = false
        workspace.submit(value)
    }

    private func beginNewRequest() {
        editingCompletion = true
        command = ""
        controller.activateForInput()
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        controller.draggingChanged(true)
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
            controller.draggingChanged(false)
        }
        return true
    }
}

private struct NotchSilhouette: Shape {
    var progress: CGFloat
    let layout: NotchLayout

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(1, max(0, progress))
        let outerWidth = layout.notchWidth + (layout.expandedWidth - layout.notchWidth) * t
        let collapsedHeight = layout.notchHeight
        let height = collapsedHeight + (layout.expandedHeight - collapsedHeight) * t
        let topLeft = rect.midX - layout.notchWidth / 2
        let topRight = rect.midX + layout.notchWidth / 2
        let left = rect.midX - outerWidth / 2
        let right = rect.midX + outerWidth / 2
        let bottom = rect.minY + height
        let shoulder = min(29, max(5, height * 0.18))
        let radius = min(26, min(15 + 11 * t, min(outerWidth / 4, height / 3)))
        var path = Path()
        path.move(to: CGPoint(x: topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: topRight, y: rect.minY))
        path.addCurve(to: CGPoint(x: right, y: rect.minY + shoulder),
                      control1: CGPoint(x: topRight + shoulder * 0.45, y: rect.minY),
                      control2: CGPoint(x: right, y: rect.minY + shoulder * 0.3))
        path.addLine(to: CGPoint(x: right, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: right - radius, y: bottom),
                          control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - radius),
                          control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: rect.minY + shoulder))
        path.addCurve(to: CGPoint(x: topLeft, y: rect.minY),
                      control1: CGPoint(x: left, y: rect.minY + shoulder * 0.3),
                      control2: CGPoint(x: topLeft - shoulder * 0.45, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct NotchInteractionRegion: Shape {
    var progress: CGFloat
    let layout: NotchLayout

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(1, max(0, progress))
        let width = layout.notchWidth + (layout.expandedWidth - layout.notchWidth) * t + 76
        let collapsedHeight = layout.notchHeight
        let height = collapsedHeight + (layout.expandedHeight - collapsedHeight) * t + 52
        let interactionRect = CGRect(x: rect.midX - width / 2, y: rect.minY,
                                     width: min(rect.width, width), height: min(rect.height, height))
        return Path(roundedRect: interactionRect, cornerRadius: min(30, interactionRect.height * 0.28))
    }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func add(_ value: URL) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}

private struct LaunchSmoke: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifting = false

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .fill(Color(white: 0.82).opacity(drifting ? 0 : 0.62))
                    .frame(width: puffSize(index), height: puffSize(index))
                    .scaleEffect(drifting ? 1.45 : 0.42)
                    .offset(x: drifting ? CGFloat(index - 2) * 13 : CGFloat(index - 2) * 3,
                            y: drifting ? -CGFloat(12 + index % 3 * 7) : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 1.08).delay(Double(index) * 0.055), value: drifting)
            }
        }
        .frame(width: 82, height: 44)
        .accessibilityHidden(true)
        .task {
            await Task.yield()
            drifting = true
        }
    }

    private func puffSize(_ index: Int) -> CGFloat {
        CGFloat(11 + (index * 7 % 10))
    }
}

private struct LandingBurst: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        ZStack {
            Ellipse()
                .stroke(Color.white.opacity(expanded ? 0 : 0.78), lineWidth: 1.8)
                .frame(width: expanded ? 92 : 10, height: expanded ? 15 : 3)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.38), value: expanded)
            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(expanded ? 0 : 0.72))
                    .frame(width: CGFloat(4 + index % 3), height: CGFloat(4 + index % 3))
                    .offset(x: expanded ? particleDistance(index) : 0,
                            y: expanded ? -CGFloat(5 + index % 3 * 3) : 3)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.32).delay(Double(index) * 0.025), value: expanded)
            }
        }
        .frame(width: 100, height: 24)
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: .milliseconds(1080))
            guard !Task.isCancelled else { return }
            expanded = true
        }
    }

    private func particleDistance(_ index: Int) -> CGFloat {
        let side: CGFloat = index.isMultiple(of: 2) ? -1 : 1
        return side * CGFloat(16 + index / 2 * 11)
    }
}
