import AppKit
import Combine
import KioCore
import KioModel
import KioTools
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
            Task { @MainActor [weak self] in self?.refreshDisplay(preferPointerScreen: true) }
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
        guard interaction.isActive(.pointer) != inside else { return }
        interaction.set(.pointer, active: inside)
        logger.info("Pointer crossed notch boundary: inside=\(inside, privacy: .public); remaining reasons=\(String(describing: self.interaction), privacy: .public)")
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
        if focused {
            cancelCollapse()
            setExpanded(true)
        } else {
            scheduleCollapse()
        }
    }

    func composingChanged(_ composing: Bool) {
        interaction.set(.composing, active: composing)
        if composing {
            cancelCollapse()
            setExpanded(true)
        } else {
            scheduleCollapse()
        }
    }

    func attachmentsChanged(_ hasAttachments: Bool) {
        interaction.set(.attachments, active: hasAttachments)
        if hasAttachments {
            cancelCollapse()
            setExpanded(true)
        } else {
            scheduleCollapse()
        }
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
        if working {
            cancelCollapse()
            setExpanded(true)
        } else {
            scheduleCollapse(after: .milliseconds(700))
        }
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

    func menuOrPopoverChanged(_ open: Bool) {
        interaction.set(.menuOrPopover, active: open)
        if open {
            cancelCollapse()
            setExpanded(true)
        } else {
            scheduleCollapse()
        }
    }

    func activateForInput(pinned: Bool = false) {
        show()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        interaction.set(.pinned, active: pinned)
        setExpanded(true)
        focusCommandRequest &+= 1
    }

    func toggleForShortcut() {
        if isExpanded {
            guard !KioWorkspace.shared.isWorking else { return }
            collapse()
        } else {
            activateForInput(pinned: true)
        }
    }

    func collapse() {
        guard !KioWorkspace.shared.isWorking else { return }
        interaction.set(.composing, active: false)
        interaction.set(.pointer, active: false)
        interaction.set(.attachments, active: false)
        interaction.set(.dragging, active: false)
        interaction.set(.pinned, active: false)
        interaction.set(.working, active: false)
        interaction.set(.resultInteraction, active: false)
        interaction.set(.menuOrPopover, active: false)
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
        interaction.shouldRemainExpanded
    }

    private func scheduleCollapse(after delay: Duration = .milliseconds(340)) {
        cancelCollapse()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            guard !self.interaction.shouldRemainExpanded else {
                self.logger.info("Notch kept open by active interaction reasons: \(String(describing: self.interaction), privacy: .public)")
                return
            }
            self.setExpanded(false, force: true)
        }
    }

    private func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    private func refreshDisplay(preferPointerScreen: Bool = false) {
        guard panel != nil else { return }
        let screen = (preferPointerScreen ? Self.screenUnderPointer() : nil)
            ?? screenNumber.flatMap { current in NSScreen.screens.first(where: { Self.number(for: $0) == current }) }
            ?? Self.preferredScreen()
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
        screenUnderPointer() ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) })
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
    @State private var pastedClipboardTexts: [String] = []
    @State private var pasteKeyMonitor: Any?
    @State private var mascotHandoff = MascotHandoffState()
    @State private var pointerGaze = CGSize.zero
    @State private var expansionProgress: CGFloat = 0
    @State private var cueSurface = false
    @State private var cueIsActive = false
    @State private var selectedReelQuality = "best"
    @State private var selectedReelFormat = "mp4"
    @State private var reelIsPreparing = false
    @State private var reelPrepareProgress = 0.0
    @State private var reelPreparationMessage: String?
    @State private var cueInitialText = ""
    @FocusState private var commandFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("kio.hoverExpansion") private var hoverExpansion = true
    @AppStorage("kio.hoverDwellMilliseconds") private var hoverDwellMilliseconds = 150

    private var inputPrompt: String {
        workspace.attachments.isEmpty ? "Ask Kio or drop files" : "Add a note for these files"
    }

    private var displayAgent: AgentID {
        NotchPresentationState.activeAgent(for: workspace.executionState)
    }

    private var targetMascotAgent: AgentID {
        guard workspace.executionState != nil, workspace.isWorking else { return .kio }
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

    private var presentationMode: NotchMode {
        NotchPresentationState.mode(cueActive: cueIsActive, cueSetup: cueSurface,
                                   preparing: reelIsPreparing, taskStatus: workspace.executionState?.status)
    }

    private var presentation: NotchPresentationState {
        NotchPresentationState(expanded: controller.isExpanded, mode: presentationMode,
                               activeAgent: displayAgent, progress: expansionProgress)
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchSilhouette(progress: expansionProgress, layout: controller.layout)
                .fill(Color.black)
                .overlay {
                    NotchSilhouette(progress: expansionProgress, layout: controller.layout)
                        .stroke(isTargeted ? Color(hex: AgentID.pixel.colorHex) : .clear, lineWidth: 1.5)
            }
            if presentation.exposesContent {
                expandedContents
                    .mask { NotchSilhouette(progress: expansionProgress, layout: controller.layout).fill(.white) }
                    .opacity(presentation.contentOpacity)
                    .allowsHitTesting(presentation.allowsContentHitTesting)
            }
        }
        .frame(width: controller.layout.hostWidth, height: controller.layout.hostHeight, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear(perform: installPasteKeyMonitor)
        .onDisappear(perform: removePasteKeyMonitor)
        .contentShape(NotchSilhouette(progress: expansionProgress, layout: controller.layout))
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                let layout = controller.layout
                let silhouette = NotchSilhouette(progress: expansionProgress, layout: layout)
                let bounds = CGRect(origin: .zero, size: CGSize(width: layout.hostWidth, height: layout.hostHeight))
                let inside = silhouette.path(in: bounds).contains(location)
                controller.pointerChanged(inside, hoverExpansion: hoverExpansion,
                                          dwellMilliseconds: hoverDwellMilliseconds)
            case .ended:
                controller.pointerChanged(false, hoverExpansion: hoverExpansion,
                                          dwellMilliseconds: hoverDwellMilliseconds)
                pointerGaze = .zero
            }
            guard !reduceMotion, controller.isExpanded else { pointerGaze = .zero; return }
            guard case .active(let location) = phase else { pointerGaze = .zero; return }
            let layout = controller.layout
            let inset = max(34, layout.screenTopInset + 8)
            let contentHeight = max(90, layout.expandedHeight - inset - 8)
            let mascotCenterX = (layout.hostWidth - layout.expandedWidth) / 2 + 16 + layout.expandedWidth * 0.31 / 2
            let mascotCenterY = inset + contentHeight / 2
            pointerGaze = CGSize(
                width: min(1, max(-1, (location.x - mascotCenterX) / max(1, layout.expandedWidth * 0.48))),
                height: min(1, max(-1, (location.y - mascotCenterY) / max(1, contentHeight * 0.48)))
            )
        }
        .onDrop(of: [UTType.fileURL, .url], isTargeted: $isTargeted, perform: acceptDrop)
        .onChange(of: isTargeted) { _, value in controller.draggingChanged(value) }
        .onChange(of: commandFocused) { _, value in controller.inputFocusChanged(value) }
        .onChange(of: command) { _, value in controller.composingChanged(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        .onChange(of: workspace.attachments.count) { _, value in controller.attachmentsChanged(value > 0) }
        .onChange(of: workspace.isWorking) { _, value in controller.workingChanged(value) }
        .onChange(of: controller.isExpanded) { _, expanded in
            withAnimation(.easeInOut(duration: reduceMotion ? 0.14 : 0.205)) {
                expansionProgress = expanded ? 1 : 0
            }
        }
        .task(id: targetMascotAgent) {
            let target = targetMascotAgent
            guard target != mascotHandoff.activeAgent else { return }

            guard controller.isExpanded else {
                mascotHandoff.assignImmediately(target)
                return
            }

            if target == .kio {
                withAnimation(.spring(response: MascotHandoffMotionPolicy.coordinatorReturnResponse, dampingFraction: 0.76)) {
                    mascotHandoff.resetToCoordinator()
                }
                return
            }

            if mascotHandoff.activeAgent == .kio {
                withAnimation(.easeInOut(duration: MascotHandoffMotionPolicy.coordinatorDepartureDuration)) {
                    mascotHandoff.beginDeparture(to: target)
                }
                try? await Task.sleep(for: MascotHandoffMotionPolicy.landingDelay)
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: MascotHandoffMotionPolicy.landingSpringResponse, dampingFraction: 0.76)) {
                    mascotHandoff.landTarget()
                }
                try? await Task.sleep(for: MascotHandoffMotionPolicy.smokeHold)
                guard !Task.isCancelled else { return }
                mascotHandoff.settle()
            } else {
                withAnimation(.spring(response: 0.72, dampingFraction: 0.76)) {
                    mascotHandoff.assignImmediately(target)
                }
            }
        }
        .onChange(of: controller.focusCommandRequest) { _, _ in
            commandFocused = true
        }
        .onExitCommand { controller.collapse() }
        .onAppear { expansionProgress = controller.isExpanded ? 1 : 0 }
        .accessibilityElement(children: .contain)
    }

    private var expandedContents: some View {
        let topInset = max(34, controller.layout.screenTopInset + 8)
        let mascotWidth = controller.layout.expandedWidth * 0.31
        let contentHeight = max(90, controller.layout.expandedHeight - topInset - 8)
        return Group {
          if cueSurface || cueIsActive {
            CueSurfaceView(onActiveChange: { cueIsActive = $0 },
                           onDone: { cueIsActive = false; cueSurface = false },
                           initialText: $cueInitialText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            HStack(spacing: 10) {
            if presentation.exposesMascot && presentationMode != .cueActive {
                mascotStage
                    .frame(width: mascotWidth, height: contentHeight)
            } else {
                Color.clear.frame(width: mascotWidth, height: contentHeight)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(panelTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if workspace.activeOutput != nil && presentationMode != .working {
                        Button { beginNewRequest() } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.68))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Start a new request")
                    }
                    historyButton
                    cueButton
                    Button { controller.collapse() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.68))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Collapse Kio")
                }
                modeContent
                if presentationMode == .idleComposer && !quickActions.isEmpty {
                    quickActionStrip
                }
                if presentationMode != .working && presentationMode != .cueActive && !workspace.attachments.isEmpty {
                    attachmentStrip
                }
                if presentationMode != .cueActive && presentationMode != .working {
                    composer
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          }
        }
        }
        .padding(.horizontal, 16)
        .padding(.top, topInset)
        .padding(.bottom, 8)
        .frame(width: controller.layout.expandedWidth, height: controller.layout.expandedHeight, alignment: .top)
    }

    private var panelTitle: String {
        if workspace.isWorking { return "\(displayAgent.name) is working" }
        if !workspace.attachments.isEmpty { return "\(workspace.attachments.count) file\(workspace.attachments.count == 1 ? "" : "s") ready" }
        if workspace.activeOutput != nil { return "Result ready" }
        return "Ready when you are"
    }

    private var mascotGaze: CGSize {
        if reduceMotion { return .zero }
        if isTargeted || commandFocused { return CGSize(width: 0.82, height: 0.12) }
        return pointerGaze
    }

    private var reelHelperRequired: Bool {
        guard displayAgent == .reel else { return false }
        let message = workspace.latestError ?? workspace.executionState?.statusText ?? ""
        let allPrepared = ReelHelperManager.helpers.allSatisfy { ReelHelperManager.isPrepared($0.id) }
            && ReelHelperManager.isPrepared("streamlink")
        return !allPrepared && (message.localizedCaseInsensitiveContains("helper") || message.localizedCaseInsensitiveContains("Prepare Reel"))
    }

    private func prepareReelHelpers() {
        guard !reelIsPreparing else { return }
        reelIsPreparing = true
        reelPrepareProgress = 0
        reelPreparationMessage = "Starting pinned Reel setup…"
        Task { @MainActor in
            defer { reelIsPreparing = false }
            do {
                try await ReelHelperManager.prepareAll { progress, message in
                    reelPrepareProgress = progress
                    reelPreparationMessage = message
                }
                reelPreparationMessage = "Reel is ready. Send the request again to continue."
            } catch {
                reelPreparationMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var modeContent: some View {
        switch presentationMode {
        case .working, .preparing:
            if reelIsPreparing {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).tint(.white.opacity(0.78))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(reelPreparationMessage ?? "Preparing Reel helpers…")
                            .font(.system(size: 9, weight: .medium)).lineLimit(1)
                        ProgressView(value: reelPrepareProgress).tint(Color(hex: AgentID.reel.colorHex))
                    }
                    Spacer(minLength: 2)
                }
                .foregroundStyle(.white.opacity(0.82)).frame(height: 47)
            } else {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).tint(.white.opacity(0.78))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(displayAgent.name) · \(workspace.executionState?.statusText ?? "Preparing…")")
                            .font(.system(size: 10, weight: .medium)).lineLimit(1)
                        if let state = workspace.executionState, state.totalStepCount > 1 {
                            ProgressView(value: Double(state.completedStepCount), total: Double(state.totalStepCount)).tint(Color(hex: displayAgent.colorHex))
                        }
                    }
                    Spacer(minLength: 2)
                    Button { workspace.cancelCurrentTask() } label: { Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).accessibilityLabel("Stop task")
                }
                .foregroundStyle(.white.opacity(0.82)).frame(height: 47)
            }
        case .result:
            if let output = workspace.activeOutput, output.fileURL.pathExtension.lowercased() == "kio-reel-info" {
                reelPicker(output).frame(height: 46)
            } else if let output = workspace.activeOutput { resultCard(output).frame(height: 46) }
            else { compactLatestMessage }
        case .clarificationError:
            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.executionState?.statusText ?? workspace.latestError ?? "What would you like me to do?")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.78)).lineLimit(2)
                if reelHelperRequired {
                    HStack(spacing: 6) {
                        Button("Prepare Reel") { prepareReelHelpers() }
                            .buttonStyle(.borderedProminent).tint(Color(hex: AgentID.reel.colorHex)).controlSize(.mini)
                        Button("Settings…") { openSettings() }
                            .buttonStyle(.plain).font(.system(size: 8, weight: .medium))
                        if let reelPreparationMessage { Text(reelPreparationMessage).font(.system(size: 8)).lineLimit(1) }
                    }
                }
            }
            .frame(height: reelHelperRequired ? 48 : 42, alignment: .leading)
        case .cueSetup:
            EmptyView()
        case .cueActive:
            EmptyView()
        case .idleComposer:
            compactLatestMessage
        }
    }

    @ViewBuilder
    private func reelPicker(_ artifact: ArtifactRef) -> some View {
        if let info = try? ReelInspectionStore.readInfo(from: artifact) {
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Menu {
                        ForEach(info.qualities, id: \.self) { quality in Button(quality) { selectedReelQuality = quality } }
                    } label: { Label(selectedReelQuality, systemImage: "arrow.up.arrow.down") }
                    Menu {
                        ForEach(info.videoFormats.isEmpty ? ["mp4"] : info.videoFormats, id: \.self) { format in Button(format.uppercased()) { selectedReelFormat = format } }
                    } label: { Label(selectedReelFormat.uppercased(), systemImage: "film") }
                    Button("Download") {
                        command = selectedReelQuality == "best" ? "download this as \(selectedReelFormat)" : "download this in \(selectedReelQuality) \(selectedReelFormat)"
                        sendCommand()
                    }
                    .buttonStyle(.borderedProminent).tint(Color(hex: AgentID.reel.colorHex)).controlSize(.mini)
                    if info.audioAvailable {
                        Button("MP3") { command = "download this as MP3"; sendCommand() }
                            .buttonStyle(.plain).font(.system(size: 8, weight: .semibold))
                    }
                }
                .font(.system(size: 8, weight: .medium))
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white.opacity(0.82))
            .onAppear {
                selectedReelQuality = info.qualities.contains("1080p") ? "1080p" : (info.qualities.first ?? "best")
                selectedReelFormat = info.videoFormats.contains("mp4") ? "mp4" : (info.videoFormats.first ?? "mp4")
            }
        } else {
            Text("Reel inspection is unavailable. Add the URL again.").font(.system(size: 9)).foregroundStyle(.orange)
        }
    }

    private var compactLatestMessage: some View {
        Group {
            if let item = workspace.conversation.last {
                Text(item.message).font(.system(size: 10)).foregroundStyle(.white.opacity(0.78)).lineLimit(2)
            } else { Text("Ready when you are").font(.system(size: 10)).foregroundStyle(.white.opacity(0.68)) }
        }
        .frame(maxWidth: .infinity, minHeight: 35, maxHeight: 42, alignment: .leading)
    }

    @ViewBuilder
    private func compactMessage(_ item: ConversationItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(item.speaker)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(item.speaker == "You" ? .white.opacity(0.55) : Color(hex: (AgentID(rawValue: item.speaker.lowercased()) ?? .kio).colorHex))
                Text(item.message)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .help(item.message)
            }
            if let artifact = item.artifact {
                resultCard(artifact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func resultCard(_ artifact: ArtifactRef) -> some View {
        if artifact.refreshedFromDisk() != nil {
            HStack(spacing: 4) {
                Image(systemName: artifact.kind == .pdf ? "doc.richtext" : "doc")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text(artifact.displayName)
                    .font(.system(size: 8, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: artifact.sizeBytes, countStyle: .file))
                    .font(.system(size: 7))
                    .foregroundStyle(.white.opacity(0.48))
                    .fixedSize()
                Spacer(minLength: 0)
                Button("Open") { NSWorkspace.shared.open(artifact.fileURL) }
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([artifact.fileURL]) }
                Button("Copy") { copyFileURL(artifact.fileURL) }
                if artifact.kind == .text && artifact.fileURL.pathExtension.lowercased() != "kio-reel-info" {
                    Button("Cue") {
                        if let script = try? String(contentsOf: artifact.fileURL, encoding: .utf8), script.utf8.count <= 500_000 {
                            cueInitialText = script
                            cueSurface = true
                        }
                    }
                    .help("Open this text result in Cue")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(Color(hex: AgentID.kio.colorHex))
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 7))
            .onHover { controller.resultInteractionChanged($0) }
            .onDrag { NSItemProvider(object: artifact.fileURL as NSURL) }
        } else {
            Label("Result unavailable · \(artifact.displayName)", systemImage: "doc.questionmark")
                .font(.system(size: 8))
                .foregroundStyle(.orange.opacity(0.8))
                .lineLimit(1)
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(workspace.attachments) { artifact in
                    NotchAttachmentChip(artifact: artifact) { workspace.removeAttachment(artifact.id) }
                }
                if workspace.attachments.count > 1 {
                    Button("Clear") { workspace.clearAttachments() }
                        .font(.system(size: 8, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 21)
    }

    private var quickActions: [ContextualQuickAction] {
        ContextualQuickActionCatalog.suggestions(for: workspace.attachments)
    }

    private var quickActionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(quickActions) { action in
                    Button(action.title) {
                        command = action.prompt
                        if action.requiresUserInput { commandFocused = true }
                        else { sendCommand() }
                    }
                    .font(.system(size: 8, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.76))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.075), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1))
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 19)
        .accessibilityLabel("Suggested actions for attached files")
    }

    private var mascotStage: some View {
        ZStack {
            AgentBlob(.kio, mood: baseMascotMood, size: 66, gazeTarget: mascotGaze)
                .offset(y: mascotHandoff.coordinatorHasDeparted ? -250 : 0)
                .zIndex(mascotHandoff.coordinatorHasDeparted ? 0 : 1)
            if mascotHandoff.launchSmokeVisible {
                LaunchSmoke()
                    .offset(y: 28)
                    .zIndex(1)
            }
            if mascotHandoff.agentHasArrived {
                AgentBlob(mascotHandoff.displayedAgent, mood: characterMood, size: 58, gazeTarget: mascotGaze)
                    .id(mascotHandoff.displayedAgent)
                    .zIndex(2)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
                LandingBurst()
                    .id(mascotHandoff.displayedAgent)
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

    private var cueButton: some View {
        Button { cueSurface.toggle() } label: {
            Image(systemName: "text.alignleft")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cueSurface ? "Close Cue setup" : "Open Cue teleprompter")
        .help("Cue")
    }

    private var composer: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isTargeted ? Color(hex: AgentID.pixel.colorHex) : Color.white.opacity(0.55))
                .accessibilityHidden(true)
            Button(action: pasteClipboardContents) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Paste text, a URL, file, or image")
            .help("Paste text, a URL, file, or image from the clipboard")
            TextField("", text: $command, prompt: Text(inputPrompt).foregroundColor(.white.opacity(0.58)), axis: .vertical)
                .font(.system(size: 12))
                .lineLimit(1...2)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .focused($commandFocused)
                .submitLabel(.send)
                .onSubmit { sendCommand() }
                .accessibilityLabel("Message Kio or drop files")
                .disabled(workspace.isWorking)
            Button {
                if workspace.isWorking { workspace.cancelCurrentTask() }
                else { sendCommand() }
            } label: {
                Image(systemName: workspace.isWorking ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(workspace.isWorking ? .white : .black)
                    .frame(width: 28, height: 28)
                    .background(workspace.isWorking ? Color.white.opacity(0.14) : Color(hex: AgentID.kio.colorHex), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!workspace.isWorking && command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(!workspace.isWorking && command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            .accessibilityLabel(workspace.isWorking ? "Stop task" : "Send message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(isTargeted ? Color(hex: AgentID.pixel.colorHex).opacity(0.14) : Color.white.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(isTargeted ? Color(hex: AgentID.pixel.colorHex) : Color.white.opacity(0.12),
                        style: StrokeStyle(lineWidth: 1, dash: isTargeted ? [6, 4] : []))
        }
    }

    private func sendCommand() {
        let submission = ClipboardComposerResolver.resolve(message: command, pastedTexts: pastedClipboardTexts)
        guard !submission.request.isEmpty || submission.pastedText != nil,
              !workspace.isWorking else { return }
        command = ""
        pastedClipboardTexts = []
        commandFocused = false
        workspace.submit(submission)
    }

    private func beginNewRequest() {
        workspace.startNewRequest()
        command = ""
        pastedClipboardTexts = []
        controller.activateForInput()
    }

    private func pasteClipboardContents() {
        let pasteboard = NSPasteboard.general
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        let input = ClipboardInputResolver.resolve(
            fileURLs: fileURLs,
            imageData: imageData,
            urlString: pasteboard.string(forType: .URL),
            text: pasteboard.string(forType: .string)
        )
        switch input {
        case .files(let urls): workspace.addURLs(urls)
        case .image(let data): workspace.addClipboardImageData(data)
        case .webURL(let value): workspace.addWebURLs([value])
        case .text(let value):
            command += value
            pastedClipboardTexts.append(value)
            commandFocused = true
        case nil: break
        }
    }

    @MainActor
    private func installPasteKeyMonitor() {
        removePasteKeyMonitor()
        let commandFocus = $commandFocused
        let pasteAction = pasteClipboardContents
        pasteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard commandFocus.wrappedValue,
                  event.window != nil,
                  event.window === NSApp.keyWindow,
                  modifiers.contains(.command),
                  !modifiers.contains(.option),
                  !modifiers.contains(.control),
                  !modifiers.contains(.shift),
                  event.charactersIgnoringModifiers?.lowercased() == "v" else {
                return event
            }

            DispatchQueue.main.async {
                pasteAction()
            }
            return nil
        }
    }

    @MainActor
    private func removePasteKeyMonitor() {
        if let pasteKeyMonitor {
            NSEvent.removeMonitor(pasteKeyMonitor)
            self.pasteKeyMonitor = nil
        }
    }

    private func copyFileURL(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        controller.draggingChanged(true)
        let collector = URLCollector()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            let type = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                ? UTType.fileURL.identifier
                : UTType.url.identifier
            guard provider.hasItemConformingToTypeIdentifier(type) else { group.leave(); continue }
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                defer { group.leave() }
                if let url = item as? URL { collector.add(url) }
                else if let url = item as? NSURL { collector.add(url as URL) }
                else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { collector.add(url) }
                else if let value = item as? String, let url = URL(string: value) { collector.add(url) }
            }
        }
        group.notify(queue: .main) {
            workspace.addURLs(collector.values.filter(\.isFileURL))
            workspace.addWebURLs(collector.values.filter { !$0.isFileURL }.map(\.absoluteString))
            controller.draggingChanged(false)
        }
        return true
    }
}

private struct NotchAttachmentChip: View {
    let artifact: ArtifactRef
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(artifact.isAvailableLocally ? Color.white.opacity(0.64) : Color.orange)
            Text(artifact.displayName)
                .font(.system(size: 8, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(artifact.isAvailableLocally ? Color.white.opacity(0.84) : Color.orange)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.74))
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(artifact.displayName)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .background(hovering ? Color.white.opacity(0.15) : Color.white.opacity(0.08), in: Capsule())
        .onHover { hovering = $0 }
        .help(artifact.isAvailableLocally ? artifact.displayName : "File unavailable: \(artifact.displayName)")
    }

    private var icon: String {
        switch artifact.kind {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .folder: "folder"
        default: "doc"
        }
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
