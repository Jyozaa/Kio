import AppKit
import KioCore
import KioModel
import KioUI
import SwiftUI
import UniformTypeIdentifiers

struct KioChatView: View {
    @ObservedObject private var workspace = KioWorkspace.shared
    @State private var message = ""
    @State private var pastedClipboardTexts: [String] = []
    @State private var historySearch = ""
    @State private var showingSearch = false
    @State private var workflowName = ""
    @State private var renameTemplateID: UUID?
    @State private var showSaveWorkflow = false
    @State private var showRenameWorkflow = false
    @State private var showWorkflowNotice = false
    @State private var workflowNotice = ""
    @State private var isPickingFiles = false
    @State private var isPickingFolder = false
    @State private var isDropTarget = false
    @State private var targetedAgent: AgentID?
    @State private var showAgentDropActions = false
    @State private var agentDropAgent: AgentID = .kio
    @State private var agentDropActions: [ChatQuickAction] = []
    @State private var pasteKeyMonitor: Any?
    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.075))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(filteredConversation) { item in
                            ConversationRow(item: item)
                                .id(item.id)
                        }
                        if !historySearch.isEmpty && filteredConversation.isEmpty {
                            ContentUnavailableView.search(text: historySearch)
                                .padding(.top, 48)
                        }
                        if workspace.isWorking {
                            HStack(spacing: 8) {
                                AgentBlob(.kio, mood: .thinking, size: 26)
                                Text("Working locally…")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.primary.opacity(0.56))
                            }
                            .padding(.leading, 4)
                        }
                    }
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .onChange(of: workspace.conversation.count) { _, _ in
                    guard let id = workspace.conversation.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            composer
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear(perform: installPasteKeyMonitor)
        .onDisappear(perform: removePasteKeyMonitor)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color(hex: AgentID.pixel.colorHex), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL, .url], isTargeted: $isDropTarget, perform: acceptDrop)
        .fileImporter(isPresented: $isPickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { workspace.addURLs(urls) }
        }
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result { workspace.addURLs(urls) }
        }
        .alert("Save Workflow", isPresented: $showSaveWorkflow) {
            TextField("Workflow name", text: $workflowName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                do { try workspace.saveWorkflowTemplate(named: workflowName); workflowNotice = "Saved \(workflowName.trimmingCharacters(in: .whitespacesAndNewlines)). Run it later from Workflows." }
                catch { workflowNotice = error.localizedDescription }
                showWorkflowNotice = true
            }
        } message: {
            Text("Save the last completed registered operation sequence for compatible files. Templates store operation names and typed arguments, not file paths.")
        }
        .alert("Workflow", isPresented: $showWorkflowNotice) {
            Button("OK", role: .cancel) {}
        } message: { Text(workflowNotice) }
        .alert("Rename Workflow", isPresented: $showRenameWorkflow) {
            TextField("Workflow name", text: $workflowName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let id = renameTemplateID,
                      let template = workspace.workflowTemplates.first(where: { $0.id == id }) else { return }
                do { try workspace.renameWorkflowTemplate(template, to: workflowName); workflowNotice = "Workflow renamed." }
                catch { workflowNotice = error.localizedDescription }
                showWorkflowNotice = true
            }
        } message: { Text("Choose a name up to 60 characters.") }
        .confirmationDialog("Choose an action for \(agentDropAgent.name)", isPresented: $showAgentDropActions, titleVisibility: .visible) {
            ForEach(agentDropActions) { action in
                Button(action.title) { workspace.submit(action.prompt) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The dropped result is attached. Choose a registered action; Kio will use the same task planner and tools.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AgentBlob(.kio, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kio").font(.system(size: 16, weight: .semibold))
                Label("On this Mac", systemImage: "circle.fill")
                    .labelStyle(StatusLabelStyle())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(hex: 0x627B6F))
            }
            Spacer()
            Menu {
                ForEach(AgentID.allCases.filter { $0 != .kio }, id: \.self) { agent in
                    Label(agent.name + " · " + agent.roleDescription, systemImage: "circle.fill")
                        .foregroundStyle(Color(hex: agent.colorHex))
                }
            } label: {
                Image(systemName: "person.3")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .frame(width: 32, height: 32)
                    .background(Color(hex: 0x1B1B1B), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .help("Crew")
            Button { showingSearch.toggle() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .frame(width: 32, height: 32)
                    .background(Color(hex: 0x1B1B1B), in: Circle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingSearch, arrowEdge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search conversation", text: $historySearch)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search local conversation and artifact history")
                    if !historySearch.isEmpty {
                        Button { historySearch = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                    }
                }
                .padding(12).frame(width: 300)
            }
            .onExitCommand { showingSearch = false }
            .help("Search history")
            workflowMenu
            Menu {
                Button("Add Files", systemImage: "paperclip") { isPickingFiles = true }
                Button("Choose Folder", systemImage: "folder") { isPickingFolder = true }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .frame(width: 32, height: 32)
                    .background(Color(hex: 0x1B1B1B), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .help("Add files or choose a folder")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
    }

    private var workflowMenu: some View {
        Menu {
            if workspace.canSaveWorkflow {
                Button("Save last workflow…", systemImage: "square.and.arrow.down") {
                    workflowName = ""
                    showSaveWorkflow = true
                }
                if !workspace.workflowTemplates.isEmpty { Divider() }
            }
            if workspace.workflowTemplates.isEmpty {
                Text("No saved workflows yet")
            } else {
                ForEach(workspace.workflowTemplates) { template in
                    Menu(template.name) {
                        Button("Run on current files", systemImage: "play.fill") {
                            message = "Run \(template.name) on these."
                            send()
                        }
                        Button("Inspect steps", systemImage: "list.bullet.rectangle") {
                            workflowNotice = template.steps.enumerated().map { "\($0.offset + 1). \($0.element.operation.rawValue)" }.joined(separator: "\n")
                            showWorkflowNotice = true
                        }
                        Button("Rename…", systemImage: "pencil") {
                            renameTemplateID = template.id
                            workflowName = template.name
                            showRenameWorkflow = true
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            do { try workspace.deleteWorkflowTemplate(template); workflowNotice = "Workflow deleted." }
                            catch { workflowNotice = error.localizedDescription }
                            showWorkflowNotice = true
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
                .frame(width: 32, height: 32)
                .background(Color(hex: 0x1B1B1B), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .help("Workflow templates")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !quickActions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(quickActions) { action in
                            Button(action.title) {
                                message = action.prompt
                                if action.requiresUserInput { messageFocused = true }
                                else { send() }
                            }
                                .font(.system(size: 10, weight: .medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.primary.opacity(0.72))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(hex: 0x171717), in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1))
                        }
                    }
                }
            }
            if !workspace.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(workspace.attachments) { file in
                            AttachmentChip(artifact: file) { workspace.removeAttachment(file.id) }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                Button { isPickingFiles = true } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .frame(width: 34, height: 36)
                }
                .buttonStyle(.plain)
                Button(action: pasteClipboardContents) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .frame(width: 30, height: 36)
                }
                .buttonStyle(.plain)
                .help("Paste text, a URL, file, or image from the clipboard")
                Button(action: workspace.captureRegion) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .frame(width: 30, height: 36)
                }
                .buttonStyle(.plain)
                .help("Capture a screen region")
                TextField(workspace.activeOutput == nil ? "Message Kio" : "Ask a follow-up…", text: $message, axis: .vertical)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .focused($messageFocused)
                    .onSubmit { send() }
                    .padding(.vertical, 10)
                Button {
                    if workspace.isWorking { workspace.cancelCurrentTask() }
                    else { send() }
                } label: {
                    Image(systemName: workspace.isWorking ? "stop.fill" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color(hex: 0x292929), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!workspace.isWorking && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(!workspace.isWorking && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(hex: 0x111111), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.09), lineWidth: 1))
            Text("Files are processed locally. Originals stay untouched.")
                .font(.system(size: 10))
                .foregroundStyle(Color.primary.opacity(0.42))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Color.black)
    }

    private func send() {
        let value = message
        message = ""
        messageFocused = false
        workspace.submit(ClipboardComposerResolver.resolve(message: value, pastedTexts: pastedClipboardTexts))
        pastedClipboardTexts = []
    }

    private var filteredConversation: [ConversationItem] {
        guard !historySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return workspace.conversation }
        let records = workspace.conversation.map {
            ConversationHistoryRecord(id: $0.id, speaker: $0.speaker, message: $0.message,
                                      artifact: $0.artifact, operation: $0.operation, createdAt: $0.createdAt)
        }
        let matchingIDs = Set(ConversationHistorySearch.filter(records, query: historySearch).map(\.id))
        return workspace.conversation.filter { matchingIDs.contains($0.id) }
    }

    private var quickActions: [ChatQuickAction] {
        ContextualQuickActionCatalog.suggestions(for: workspace.attachments)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let collector = ChatURLCollector()
        providers.forEach { provider in
            let type = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL.identifier : UTType.url.identifier
            guard provider.hasItemConformingToTypeIdentifier(type) else { return }
            group.enter()
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                defer { group.leave() }
                if let url = item as? URL { collector.append(url) }
                else if let url = item as? NSURL { collector.append(url as URL) }
                else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { collector.append(url) }
                else if let value = item as? String, let url = URL(string: value) { collector.append(url) }
            }
        }
        group.notify(queue: .main) {
            let dropped = collector.urls
            workspace.addURLs(dropped.filter(\.isFileURL))
            workspace.addWebURLs(dropped.filter { !$0.isFileURL }.map(\.absoluteString))
        }
        return true
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
            message += value
            pastedClipboardTexts.append(value)
            messageFocused = true
        case nil: break
        }
    }

    @MainActor
    private func installPasteKeyMonitor() {
        removePasteKeyMonitor()
        let messageFocus = $messageFocused
        let pasteAction = pasteClipboardContents
        pasteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard messageFocus.wrappedValue,
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

    private func acceptSpecialistDrop(_ providers: [NSItemProvider], agent: AgentID) -> Bool {
        let group = DispatchGroup()
        let collector = ChatURLCollector()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let url = item as? URL { collector.append(url) }
                else if let url = item as? NSURL { collector.append(url as URL) }
                else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { collector.append(url) }
            }
        }
        group.notify(queue: .main) {
            let urls = collector.urls.filter(\.isFileURL)
            guard !urls.isEmpty else { return }
            workspace.addURLs(urls)
            agentDropAgent = agent
            agentDropActions = specialistActions(for: agent, urls: urls)
            if agentDropActions.isEmpty {
                workflowNotice = "No registered \(agent.name) action matches the dropped file type."
                showWorkflowNotice = true
            } else {
                showAgentDropActions = true
            }
        }
        return true
    }

    private func specialistActions(for agent: AgentID, urls: [URL]) -> [ChatQuickAction] {
        let artifacts = urls.compactMap { try? ArtifactRef.inspect($0) }
        let kinds = artifacts.map(\.kind)
        switch agent {
        case .pip:
            let pdfs = kinds.filter { $0 == .pdf }.count
            guard pdfs > 0 else { return [] }
            if pdfs > 1 { return [.init(title: "Merge PDFs", prompt: "Merge these PDFs")] }
            return [.init(title: "Split pages", prompt: "Split this PDF into pages"), .init(title: "Extract text", prompt: "Extract text from this PDF"), .init(title: "Summarize", prompt: "Summarize this PDF"), .init(title: "OCR", prompt: "OCR this PDF")]
        case .pixel:
            guard kinds.contains(.image) else { return [] }
            return [.init(title: "Resize 1200 px", prompt: "Resize this image to 1200 pixels wide"), .init(title: "Convert to PNG", prompt: "Convert this image to PNG"), .init(title: "Compress", prompt: "Compress this image"), .init(title: "Remove background", prompt: "Remove the background from this image"), .init(title: "OCR", prompt: "Extract the text from this image")]
        case .zip:
            if artifacts.contains(where: { $0.fileURL.pathExtension.lowercased() == "zip" }) {
                return [.init(title: "Inspect ZIP", prompt: "Inspect this ZIP archive"), .init(title: "Extract ZIP", prompt: "Extract this ZIP archive")]
            }
            return artifacts.isEmpty ? [] : [.init(title: "Create ZIP", prompt: "Create a ZIP archive from these files")]
        case .echo:
            if kinds.contains(.video) { return [.init(title: "Extract audio", prompt: "Extract audio from this video"), .init(title: "Transcribe", prompt: "Transcribe this video"), .init(title: "Subtitles", prompt: "Generate subtitles for this video")] }
            if kinds.contains(.audio) { return [.init(title: "Transcribe", prompt: "Transcribe this audio"), .init(title: "Subtitles", prompt: "Generate subtitles for this audio")] }
            return []
        case .clerk:
            guard !artifacts.isEmpty, artifacts.allSatisfy({ $0.kind != .folder }) else { return [] }
            return [.init(title: "Organize by type", prompt: "Organize these files by type"), .init(title: "Organize by module", prompt: "Organize these files by filename module prefix"), .init(title: "Find duplicates", prompt: "Find exact duplicate files among these")]
        case .scribe:
            if kinds.contains(.text) { return [.init(title: "Summarize", prompt: "Summarize this text"), .init(title: "Proofread", prompt: "Proofread this text")] }
            return []
        case .table:
            guard kinds.contains(.csv) || kinds.contains(.table) else { return [] }
            if artifacts.contains(where: { $0.fileURL.pathExtension.lowercased() == "xlsx" }) {
                return [.init(title: "Import workbook", prompt: "Import this workbook to CSV"), .init(title: "Inspect workbook", prompt: "Inspect this workbook")]
            }
            return [.init(title: "Inspect", prompt: "Inspect this table"), .init(title: "Normalize", prompt: "Normalize this table"), .init(title: "Deduplicate", prompt: "Remove duplicate rows")]
        case .lens:
            guard kinds.contains(.image) else { return [] }
            return [.init(title: "Read text", prompt: "Extract the text from this image"), .init(title: "Extract table", prompt: "Extract the table from this image"), .init(title: "Receipt", prompt: "Extract the fields from this receipt")]
        case .scout:
            guard kinds.contains(.url) else { return [] }
            return [.init(title: "Summarize page", prompt: "Summarize this page"), .init(title: "List links", prompt: "Extract links from this page")]
        case .patch:
            guard artifacts.contains(where: { $0.kind == .text && ["swift", "py", "js", "ts", "tsx", "rs", "go", "java", "c", "cpp"].contains($0.fileURL.pathExtension.lowercased()) }) else { return [] }
            return [.init(title: "Explain code", prompt: "Explain this code"), .init(title: "Propose patch", prompt: "Propose a patch for this code")]
        case .reel:
            guard kinds.contains(.url) else { return [] }
            return [.init(title: "Inspect media", prompt: "Inspect this online media"), .init(title: "Download media", prompt: "Download this")]
        case .cue:
            return []
        case .kio, .courier:
            return []
        }
    }
}

private typealias ChatQuickAction = ContextualQuickAction

private struct ConversationRow: View {
    let item: ConversationItem

    var body: some View {
        if item.speaker == "You" {
            HStack {
                Spacer(minLength: 64)
                Text(item.message)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(Color(hex: 0x252525), in: RoundedRectangle(cornerRadius: 17))
            }
        } else {
            HStack(alignment: .top, spacing: 11) {
                AgentBlob(agent(for: item.speaker), mood: item.artifact == nil ? .idle : .success, size: 29)
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.speaker).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.63))
                    Text(item.message).font(.system(size: 14)).foregroundStyle(Color.primary.opacity(0.88)).textSelection(.enabled)
                    if let artifact = item.artifact {
                        if artifact.refreshedFromDisk() != nil { ArtifactCard(artifact: artifact) }
                        else {
                            Label("Historical result · \(artifact.displayName) is no longer available", systemImage: "doc.questionmark")
                                .font(.system(size: 11)).foregroundStyle(Color.secondary)
                        }
                    }
                }
                Spacer(minLength: 48)
            }
        }
    }

    private func agent(for speaker: String) -> AgentID {
        AgentID(rawValue: speaker.lowercased()) ?? .kio
    }
}

private struct AttachmentChip: View {
    let artifact: ArtifactRef
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.58))
            Text(artifact.displayName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.primary.opacity(0.36)) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color(hex: 0x171717), in: RoundedRectangle(cornerRadius: 10))
    }

    private var icon: String {
        switch artifact.kind {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .csv, .table: "tablecells"
        case .url: "link"
        case .folder: "folder"
        default: "doc"
        }
    }
}

private struct ArtifactCard: View {
    let artifact: ArtifactRef

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: artifact.kind == .pdf ? "doc.richtext.fill" : "doc.fill")
                .font(.system(size: 17))
                .foregroundStyle(Color(hex: 0x748A7F))
                .frame(width: 38, height: 42)
                .background(Color(hex: 0x202020), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(artifact.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: artifact.sizeBytes, countStyle: .file))
                    .font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.48))
                if let note = artifact.verificationNote {
                    Text(note).font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.48)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button("Open") { NSWorkspace.shared.open(artifact.fileURL) }
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([artifact.fileURL]) }
            if artifact.kind == .text, artifact.fileURL.pathExtension.lowercased() == "md" {
                Button("Copy text") {
                    guard let text = try? String(contentsOf: artifact.fileURL, encoding: .utf8) else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                }
                Button("Save as TXT") { savePlainTextCopy() }
            }
            Button("Copy file") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([artifact.fileURL as NSURL])
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10, weight: .medium))
        .padding(10)
        .frame(maxWidth: 420)
        .background(Color(hex: 0x141414), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.075), lineWidth: 1))
        .onDrag { NSItemProvider(object: artifact.fileURL as NSURL) }
        .contextMenu {
            Button("Copy file") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([artifact.fileURL as NSURL])
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([artifact.fileURL]) }
        }
    }

    private func savePlainTextCopy() {
        guard let text = try? String(contentsOf: artifact.fileURL, encoding: .utf8) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = artifact.fileURL.deletingPathExtension().lastPathComponent + ".txt"
        panel.prompt = "Save TXT"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try text.write(to: destination, atomically: true, encoding: .utf8) }
        catch { NSAlert(error: error).runModal() }
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 5))
            configuration.title
        }
    }
}

private final class ChatURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}
