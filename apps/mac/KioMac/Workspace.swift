import AppKit
import Combine
import Foundation
import KioCore
import KioInference
import KioModel
import KioSync
import KioTools

struct ConversationItem: Identifiable, Sendable {
    let id: UUID
    let speaker: String
    let message: String
    let artifact: ArtifactRef?
    let createdAt: Date
    let operation: ToolOperation?

    init(id: UUID = UUID(), speaker: String, message: String, artifact: ArtifactRef?, createdAt: Date = .now, operation: ToolOperation? = nil) {
        self.id = id
        self.speaker = speaker
        self.message = message
        self.artifact = artifact
        self.createdAt = createdAt
        self.operation = operation
    }
}

@MainActor
final class KioWorkspace: ObservableObject {
    private struct PendingRemoteRequest {
        let phoneID: String
        let payload: RelayPayload
        let stagedAttachmentURLs: [URL]
    }

    static let shared = KioWorkspace()

    @Published private(set) var attachments: [ArtifactRef] = []
    @Published private(set) var conversation: [ConversationItem]
    @Published private(set) var isWorking = false
    @Published private(set) var activeOutput: ArtifactRef?
    @Published private(set) var latestError: String?
    @Published private(set) var executionState: TaskExecutionState?
    @Published private(set) var workflowTemplates: [WorkflowTemplate] = WorkflowTemplateStore().load()

    private var lastOperation: ToolOperation?
    private var lastPlan: TaskPlan?
    private var runningTask: Task<Void, Never>?
    private var pendingRemoteRequests: [PendingRemoteRequest] = []
    private var lastSuccessfulInputs: [ArtifactRef] = []
    private var temporaryClipboardArtifactIDs: Set<UUID> = []
    private var remoteTaskLedger = TaskDeduplicationLedger(knownIDs: UserDefaults.standard.stringArray(forKey: "kio.processedRemoteTaskIDs") ?? [])
    private let planner = FastPathPlanner()
    private let templateStore = WorkflowTemplateStore()
    private let artifactContextResolver = ArtifactContextResolver()
    private let fastResponseResolver = FastPathResponseResolver()
    private let executor = ToolExecutor(localTextTransform: { systemInstruction, userPrompt, maxTokens in
        try await LocalModelManager.shared.generateText(
            systemInstruction: systemInstruction,
            userPrompt: userPrompt,
            maxTokens: maxTokens
        )
    })

    private init() {
        if let restored = ConversationPersistence.restore() {
            conversation = restored.items
            activeOutput = restored.activeOutput
            ConversationPersistence.saveActiveOutput(restored.activeOutput)
            lastOperation = restored.operation
            lastPlan = restored.plan
            if restored.hadUnavailableActiveOutput {
                conversation.append(ConversationItem(speaker: "Kio", message: "The last result file is no longer available. Add the file again before asking me to work with it.", artifact: nil))
            }
        } else {
            conversation = [ConversationItem(speaker: "Kio", message: "Drop in a file and tell me what you want done. Kio processes files on this Mac. You can install an optional 1.72 GB local model in Settings for broader request planning.", artifact: nil)]
        }
    }

    func addURLs(_ urls: [URL]) {
        let known = Set(attachments.map { $0.fileURL.standardizedFileURL })
        var added: [ArtifactRef] = []
        for url in urls where url.isFileURL && !known.contains(url.standardizedFileURL) {
            do { added.append(try ArtifactRef.inspect(url)) }
            catch { append("Kio", "I couldn't read \(url.lastPathComponent): \(error.localizedDescription)") }
        }
        guard !added.isEmpty else { return }
        attachments.append(contentsOf: added)
        let names = added.prefix(3).map(\.displayName).joined(separator: ", ")
        let remaining = added.count > 3 ? " and \(added.count - 3) more" : ""
        append("Kio", "Got \(added.count) file\(added.count == 1 ? "" : "s"): \(names)\(remaining).")
        latestError = nil
    }

    func addClipboardImageData(_ data: Data) {
        guard !data.isEmpty, data.count <= 25 * 1_024 * 1_024, let image = NSImage(data: data),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            append("Kio", "I couldn't read an image from the clipboard.")
            return
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kio/ClipboardInbox", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.pruneOldClipboardFiles(in: directory)
            let destination = directory.appendingPathComponent("Clipboard-\(UUID().uuidString).png")
            try png.write(to: destination, options: .atomic)
            let existingIDs = Set(attachments.map(\.id))
            addURLs([destination])
            temporaryClipboardArtifactIDs.formUnion(attachments.filter { !existingIDs.contains($0.id) }.map(\.id))
        } catch { append("Kio", "I couldn't save the clipboard image: \(error.localizedDescription)") }
    }

    private func addClipboardText(_ text: String) -> Bool {
        let data = Data(text.utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, data.count <= 4_000_000 else {
            append("Kio", "I couldn't use that pasted text. Paste non-empty UTF-8 text under 4 MB.")
            return false
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kio/ClipboardInbox", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.pruneOldClipboardFiles(in: directory)
            let destination = directory.appendingPathComponent("Clipboard-\(UUID().uuidString).txt")
            try data.write(to: destination, options: .atomic)
            let artifact = try ArtifactRef.inspect(destination)
            attachments.append(artifact)
            temporaryClipboardArtifactIDs.insert(artifact.id)
            latestError = nil
            return true
        } catch {
            append("Kio", "I couldn't save the pasted text: \(error.localizedDescription)")
            return false
        }
    }

    func captureRegion() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kio/ClipboardInbox", isDirectory: true)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                Self.pruneOldClipboardFiles(in: directory)
                let destination = directory.appendingPathComponent("Capture-\(UUID().uuidString).png")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", destination.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0, let artifact = try? ArtifactRef.inspect(destination), artifact.kind == .image, artifact.sizeBytes > 0 else {
                    try? FileManager.default.removeItem(at: destination)
                    return
                }
                await MainActor.run { self?.addURLs([destination]) }
            } catch {
                await MainActor.run { self?.append("Kio", "The region capture did not complete: \(error.localizedDescription)") }
            }
        }
    }

    private nonisolated static func pruneOldClipboardFiles(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date.now.timeIntervalSince(modified) > 14 * 24 * 60 * 60 { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func removeTemporaryClipboardArtifacts(withIDs ids: Set<UUID>) {
        let temporary = attachments.filter { ids.contains($0.id) && temporaryClipboardArtifactIDs.contains($0.id) }
        for artifact in temporary { try? FileManager.default.removeItem(at: artifact.fileURL) }
        temporaryClipboardArtifactIDs.subtract(temporary.map(\.id))
    }

    func addWebURLs(_ values: [String]) {
        var known = Set(attachments.filter { $0.kind == .url }.map { $0.fileURL.standardizedFileURL })
        var added: [ArtifactRef] = []
        for value in values.prefix(8) {
            do {
                let reference = try ScoutInputStore.makeArtifact(from: value)
                guard known.insert(reference.fileURL.standardizedFileURL).inserted else { continue }
                added.append(reference)
            } catch {
                append("Kio", "I couldn't accept that URL. Use a public http:// or https:// page without local-network access.")
            }
        }
        guard !added.isEmpty else { return }
        attachments.append(contentsOf: added)
        append("Kio", "Added \(added.count) web URL\(added.count == 1 ? "" : "s") for Scout.")
        latestError = nil
    }

    func removeAttachment(_ id: UUID) {
        removeTemporaryClipboardArtifacts(withIDs: [id])
        attachments.removeAll { $0.id == id }
    }

    func clearAttachments() {
        removeTemporaryClipboardArtifacts(withIDs: Set(attachments.map(\.id)))
        attachments.removeAll()
    }

    func startNewRequest() {
        guard !isWorking else { return }
        removeTemporaryClipboardArtifacts(withIDs: Set(attachments.map(\.id)))
        attachments = []
        activeOutput = nil
        ConversationPersistence.saveActiveOutput(nil)
        lastOperation = nil
        lastPlan = nil
        latestError = nil
        executionState = nil
        ConversationPersistence.saveLastPlan(nil)
    }

    var canSaveWorkflow: Bool { lastPlan != nil && !lastSuccessfulInputs.isEmpty }

    func saveWorkflowTemplate(named name: String) throws {
        guard let lastPlan, !lastSuccessfulInputs.isEmpty else { throw KioFailure.invalidInput("Finish a successful workflow before saving it.") }
        workflowTemplates = try templateStore.save(name: name, plan: lastPlan, inputs: lastSuccessfulInputs)
    }

    func renameWorkflowTemplate(_ template: WorkflowTemplate, to name: String) throws {
        workflowTemplates = try templateStore.rename(id: template.id, to: name)
    }

    func deleteWorkflowTemplate(_ template: WorkflowTemplate) throws {
        workflowTemplates = try templateStore.delete(id: template.id)
    }

    func submit(_ rawRequest: String) {
        submit(rawRequest, remote: nil, pastedText: nil)
    }

    func submit(_ submission: ClipboardComposerSubmission) {
        submit(submission.request, remote: nil, pastedText: submission.pastedText)
    }

    func receiveRemoteRequest(from phoneID: String, payload: RelayPayload, attachmentData: [Data]?) {
        guard payload.type == "request", let taskID = payload.taskID else { return }
        guard payload.text.count <= 2_000, !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Task { await LocalRelayManager.shared.sendReply(type: "error", text: "That request is empty or too long to send safely.", taskID: taskID, artifactURL: nil, to: phoneID) }
            return
        }
        guard remoteTaskLedger.insertIfNew(taskID) else {
            Task { await LocalRelayManager.shared.sendReply(type: "progress", text: "This request was already accepted and won't run twice.", taskID: taskID, artifactURL: nil, to: phoneID, speaker: "Kio", agent: AgentID.kio.rawValue) }
            return
        }
        UserDefaults.standard.set(remoteTaskLedger.entries, forKey: "kio.processedRemoteTaskIDs")
        let hasAttachments = payload.attachments?.isEmpty == false || payload.attachmentID != nil
        if !hasAttachments, let answer = fastResponseResolver.response(to: payload.text) {
            append("Phone", payload.text)
            append("Kio", answer)
            Task { await LocalRelayManager.shared.sendReply(type: "result", text: answer, taskID: taskID, artifactURL: nil, to: phoneID) }
            return
        }
        var stagedAttachmentURLs: [URL] = []
        do {
            if hasAttachments {
                let manifest: [(String, Int, String)]
                if let attachments = payload.attachments {
                    guard !attachments.isEmpty, attachments.count <= 8,
                          attachments.allSatisfy({ (1...(50 * 1_024 * 1_024)).contains($0.size) }),
                          attachments.reduce(0, { $0 + $1.size }) <= 150 * 1_024 * 1_024 else {
                        throw KioFailure.invalidInput("This phone request exceeds Kio's attachment limits.")
                    }
                    manifest = attachments.map { ($0.name, $0.size, $0.mime) }
                } else if let name = payload.artifactName, let size = payload.artifactSize {
                    manifest = [(name, size, payload.artifactMime ?? "application/octet-stream")]
                } else { throw KioFailure.invalidInput("This phone attachment is missing its file details.") }
                guard let attachmentData, attachmentData.count == manifest.count,
                      zip(attachmentData, manifest).allSatisfy({ pair in pair.0.count == pair.1.1 && pair.0.count <= 50 * 1_024 * 1_024 }),
                      attachmentData.reduce(0, { $0 + $1.count }) <= 150 * 1_024 * 1_024 else {
                    throw KioFailure.invalidInput("A phone attachment could not be verified.")
                }
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let inbox = support.appendingPathComponent("Kio/RelayInbox", isDirectory: true)
                try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                for (data, item) in zip(attachmentData, manifest) {
                    let fileURL = inbox.appendingPathComponent(UUID().uuidString + "-" + Self.safeFileName(item.0))
                    try data.write(to: fileURL, options: .atomic)
                    stagedAttachmentURLs.append(fileURL)
                }
            }
            if isWorking {
                guard pendingRemoteRequests.count < 3 else { throw KioFailure.invalidInput("The Mac already has three phone requests waiting. Try again when one finishes.") }
                pendingRemoteRequests.append(PendingRemoteRequest(phoneID: phoneID, payload: payload, stagedAttachmentURLs: stagedAttachmentURLs))
                append("Kio", "Added your phone request to the Mac queue.")
                Task { await LocalRelayManager.shared.sendReply(type: "progress", text: "Added to the Mac queue. It will start after the current task.", taskID: taskID, artifactURL: nil, to: phoneID) }
                return
            }
            startRemoteRequest(from: phoneID, payload: payload, stagedAttachmentURLs: stagedAttachmentURLs)
        } catch {
            for url in stagedAttachmentURLs { try? FileManager.default.removeItem(at: url) }
            append("Kio", "I couldn't receive that phone attachment: \(error.localizedDescription)")
            Task { await LocalRelayManager.shared.sendReply(type: "error", text: error.localizedDescription, taskID: taskID, artifactURL: nil, to: phoneID) }
        }
    }

    private func startRemoteRequest(from phoneID: String, payload: RelayPayload, stagedAttachmentURLs: [URL]) {
        guard let taskID = payload.taskID else { return }
        var inputURLs: [URL] = []
        do {
            let names = payload.attachments?.map(\.name) ?? (payload.artifactName.map { [$0] } ?? [])
            for (index, stagedAttachmentURL) in stagedAttachmentURLs.enumerated() {
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Kio", isDirectory: true)
                try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
                let fallbackName = stagedAttachmentURL.lastPathComponent
                let displayName = index < names.count ? names[index] : fallbackName
                let destination = downloads.appendingPathComponent("Phone-\(UUID().uuidString)-\(Self.safeFileName(displayName))")
                try FileManager.default.copyItem(at: stagedAttachmentURL, to: destination)
                attachments.append(try ArtifactRef.inspect(destination))
                inputURLs.append(destination)
                try? FileManager.default.removeItem(at: stagedAttachmentURL)
            }
            let inlineText = inputURLs.isEmpty ? InlineTextSubmissionResolver.resolve(message: payload.text) : nil
            submit(inlineText?.request ?? payload.text, remote: (phoneID, taskID, inputURLs), pastedText: inlineText?.pastedText)
        } catch {
            for url in inputURLs { try? FileManager.default.removeItem(at: url) }
            for url in stagedAttachmentURLs { try? FileManager.default.removeItem(at: url) }
            append("Kio", "I couldn't prepare the phone request: \(error.localizedDescription)")
            Task { await LocalRelayManager.shared.sendReply(type: "error", text: error.localizedDescription, taskID: taskID, artifactURL: nil, to: phoneID) }
        }
    }

    private func submit(_ rawRequest: String, remote: (phoneID: String, taskID: String, inputURLs: [URL])?, pastedText: String? = nil) {
        let embeddedURLs = Self.webURLs(in: rawRequest)
        let cleanedRequest = Self.removingWebURLs(from: rawRequest)
        let request = (cleanedRequest.isEmpty && !embeddedURLs.isEmpty ? "Summarize this page." : cleanedRequest)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isWorking else { return }
        if request.isEmpty, let pastedText {
            guard addClipboardText(pastedText) else { return }
            append("You", "Pasted text (\(pastedText.count) characters)")
            append("Kio", "I added the pasted text. What would you like me to do with it? You can ask me to summarize, rewrite, proofread, translate, or extract key points.")
            return
        }
        guard !request.isEmpty else { return }
        if let pastedText, !addClipboardText(pastedText) { return }
        if !embeddedURLs.isEmpty {
            guard embeddedURLs.count <= 8 else { append("Kio", "Add up to eight URLs per request."); return }
            do {
                let references = try embeddedURLs.map { try ScoutInputStore.makeArtifact(from: $0) }
                var known = Set(attachments.filter { $0.kind == .url }.map { $0.fileURL.standardizedFileURL })
                attachments.append(contentsOf: references.filter { known.insert($0.fileURL.standardizedFileURL).inserted })
            } catch {
                append("Kio", "I couldn't use that URL. Scout accepts public http:// and https:// pages only.")
                return
            }
        }
        if remote == nil, attachments.isEmpty, let answer = fastResponseResolver.response(to: request) {
            activeOutput = nil
            ConversationPersistence.saveActiveOutput(nil)
            lastOperation = nil
            lastPlan = nil
            latestError = nil
            executionState = nil
            ConversationPersistence.saveLastPlan(nil)
            append("You", request)
            append("Kio", answer)
            return
        }
        let researchQueryArtifact: ArtifactRef?
        if attachments.isEmpty, let topic = Self.researchTopic(in: request) {
            do { researchQueryArtifact = try ScoutInputStore.makeResearchQuery(topic) }
            catch { append("Kio", "I couldn't prepare that research topic safely: \(error.localizedDescription)"); return }
        } else {
            researchQueryArtifact = nil
        }
        if activeOutput != nil, activeOutput?.refreshedFromDisk() == nil {
            activeOutput = nil
            ConversationPersistence.saveActiveOutput(nil)
            lastOperation = nil
            lastPlan = nil
            ConversationPersistence.saveLastPlan(nil)
            append("Kio", "The previous result file is no longer available. Add it again before asking me to work with it.")
        } else if let current = activeOutput?.refreshedFromDisk() {
            activeOutput = current
        }
        let attachedWebNames = attachments.filter { $0.kind == .url }.map(\.displayName)
        var message = attachedWebNames.isEmpty ? request : "\(request)\n\(attachedWebNames.joined(separator: "\n"))"
        if let pastedText { message += "\nPasted text attached (\(pastedText.count) characters)." }
        let historyArtifacts = conversation.compactMap { item -> ArtifactContextEntry? in
            guard let artifact = item.artifact else { return nil }
            return ArtifactContextEntry(artifact: artifact, operation: item.operation, speaker: item.speaker, createdAt: item.createdAt)
        }
        let mostRecentTaskArtifacts = recentTaskArtifactEntries()
        append(remote == nil ? "You" : "Phone", message)
        latestError = nil
        var contextClarification: String?
        let planningArtifacts: [ArtifactRef]
        if let researchQueryArtifact {
            planningArtifacts = [researchQueryArtifact]
        } else if !attachments.isEmpty {
            planningArtifacts = attachments
        } else {
            switch artifactContextResolver.resolve(request: request, history: historyArtifacts, mostRecentTaskResults: mostRecentTaskArtifacts) {
            case .notReferenced:
                planningArtifacts = activeOutput.map { [$0] } ?? []
            case .resolved(let artifact):
                planningArtifacts = [artifact]
            case .clarify(let question):
                planningArtifacts = []
                contextClarification = question
            }
        }
        let submittedAttachmentIDs = Set(attachments.map(\.id))
        let context = PlanningContext(activeOutput: activeOutput, previousOperation: lastOperation, previousPlan: lastPlan)
        if attachments.isEmpty, WorkflowTemplateStore.isListingRequest(request) {
            let reply = templateStore.listingReply()
            append(remote == nil ? "You" : "Phone", request)
            append("Kio", reply)
            if let remote {
                Task {
                    await LocalRelayManager.shared.sendReply(
                        type: "result", text: reply, taskID: remote.taskID, artifactURL: nil,
                        to: remote.phoneID, speaker: AgentID.kio.name, agent: AgentID.kio.rawValue
                    )
                }
            }
            return
        }
        let templateName = WorkflowTemplateStore.requestedName(in: request)
        let fastPlan: TaskPlan
        if let templateName {
            if let template = workflowTemplates.first(where: { $0.name.localizedCaseInsensitiveCompare(templateName) == .orderedSame }) {
                do { fastPlan = try templateStore.instantiate(template, request: request, inputs: planningArtifacts) }
                catch { fastPlan = TaskPlan(request: request, steps: [], clarification: error.localizedDescription) }
            } else {
                fastPlan = TaskPlan(request: request, steps: [], clarification: "I don't have a saved workflow named \(templateName). Choose one from Workflows or save a completed workflow first.")
            }
        } else {
            fastPlan = planner.plan(request: request, artifacts: planningArtifacts, context: context)
        }
        publishExecution(for: fastPlan, status: .planning, text: "Planning your task…")
        isWorking = true
        runningTask = Task {
            defer {
                isWorking = false
                runningTask = nil
                for inputURL in remote?.inputURLs ?? [] {
                    try? FileManager.default.removeItem(at: inputURL)
                    attachments.removeAll { $0.fileURL.standardizedFileURL == inputURL.standardizedFileURL }
                }
                if let researchQueryArtifact { try? FileManager.default.removeItem(at: researchQueryArtifact.fileURL) }
                if !pendingRemoteRequests.isEmpty {
                    let next = pendingRemoteRequests.removeFirst()
                    startRemoteRequest(from: next.phoneID, payload: next.payload, stagedAttachmentURLs: next.stagedAttachmentURLs)
                }
            }
            var plan = fastPlan
            if plan.steps.isEmpty {
                if templateName != nil {
                    let message = plan.clarification ?? "That saved workflow can't use these inputs."
                    publishExecution(for: plan, status: .waitingForUser, text: message)
                    append("Kio", message)
                    if let remote { await LocalRelayManager.shared.sendReply(type: "error", text: message, taskID: remote.taskID, artifactURL: nil, to: remote.phoneID) }
                    return
                }
                if let contextClarification {
                    publishExecution(for: plan, status: .waitingForUser, text: contextClarification)
                    append("Kio", contextClarification)
                    if let remote { await LocalRelayManager.shared.sendReply(type: "error", text: contextClarification, taskID: remote.taskID, artifactURL: nil, to: remote.phoneID) }
                    return
                }
                guard LocalModelManager.shared.isInstalled else {
                    let message = plan.clarification ?? "I need a clearer instruction for that."
                    publishExecution(for: plan, status: .waitingForUser, text: message)
                    append("Kio", "\(message) A local model can plan other registered workflows after you prepare it in Settings.")
                    if let remote { await LocalRelayManager.shared.sendReply(type: "error", text: message, taskID: remote.taskID, artifactURL: nil, to: remote.phoneID) }
                    return
                }
                append("Kio", "Planning with the local model…")
                if let remote { await LocalRelayManager.shared.sendReply(type: "progress", text: "Kio is checking the request against its registered tools.", taskID: remote.taskID, artifactURL: nil, to: remote.phoneID, speaker: "Kio", agent: AgentID.kio.rawValue) }
                do {
                    guard let modelPlan = try await LocalModelManager.shared.plan(request: request, artifacts: planningArtifacts) else {
                        let message = "I couldn't verify a safe tool plan for that request. Try adding a little more detail."
                        publishExecution(for: plan, status: .waitingForUser, text: message)
                        append("Kio", message)
                        if let remote { await LocalRelayManager.shared.sendReply(type: "error", text: message, taskID: remote.taskID, artifactURL: nil, to: remote.phoneID) }
                        return
                    }
                    plan = modelPlan
                } catch is CancellationError {
                    publishExecution(for: plan, status: .cancelled, text: "Stopped before making changes.")
                    append("Kio", "Stopped before making changes.")
                    if let remote { await LocalRelayManager.shared.sendReply(type: "error", text: "Stopped before making changes.", taskID: remote.taskID, artifactURL: nil, to: remote.phoneID) }
                    return
                } catch {
                    latestError = error.localizedDescription
                    publishExecution(for: plan, status: .failed, text: error.localizedDescription, failure: error.localizedDescription)
                    append("Kio", "The local model couldn't plan this safely: \(error.localizedDescription)")
                    if let remote { await LocalRelayManager.shared.sendReply(type: "error", text: "The local model couldn't plan this safely: \(error.localizedDescription)", taskID: remote.taskID, artifactURL: nil, to: remote.phoneID) }
                    return
                }
            }
            guard !plan.steps.isEmpty else {
                let message = plan.clarification ?? "I need a clearer instruction for that."
                publishExecution(for: plan, status: .waitingForUser, text: message)
                append("Kio", message)
                if let remote { await LocalRelayManager.shared.sendReply(type: "error", text: message, taskID: remote.taskID, artifactURL: nil, to: remote.phoneID) }
                return
            }
            publishExecution(for: plan, status: .running, text: "Starting \(plan.steps[0].owner.name)'s step.", total: plan.steps.count)
            let result = await execute(plan, inputSnapshot: planningArtifacts, remote: remote.map { ($0.phoneID, $0.taskID) })
            if result != nil {
                removeTemporaryClipboardArtifacts(withIDs: submittedAttachmentIDs)
                attachments.removeAll { submittedAttachmentIDs.contains($0.id) }
                lastPlan = plan
                lastSuccessfulInputs = planningArtifacts
                workflowTemplates = templateStore.load()
                ConversationPersistence.saveLastPlan(plan)
            }
            guard let remote else { return }
            if let result {
                let relayFiles = Array(result.prefix(8).map(\.fileURL))
                let extra = result.count > relayFiles.count ? " The remaining files are available on the Mac." : ""
                await LocalRelayManager.shared.sendReply(type: "result", text: "Done. \(result.count) result file\(result.count == 1 ? "" : "s") are ready.\(extra)", taskID: remote.taskID, artifactURL: nil, artifactURLs: relayFiles, to: remote.phoneID, speaker: "Kio", agent: AgentID.kio.rawValue)
            } else {
                let message = latestError ?? "Kio stopped before creating a result."
                let agent = executionState?.activeAgent ?? .kio
                await LocalRelayManager.shared.sendReply(type: "error", text: message, taskID: remote.taskID, artifactURL: nil, to: remote.phoneID, speaker: agent.name, agent: agent.rawValue)
            }
        }
    }

    func cancelCurrentTask() { runningTask?.cancel() }

    private func execute(_ plan: TaskPlan, inputSnapshot: [ArtifactRef], remote: (phoneID: String, taskID: String)?) async -> [ArtifactRef]? {
        var artifactSnapshot = PlanArtifactSnapshot(originals: inputSnapshot)
        var finalOutputs: [ArtifactRef] = []
        for (stepIndex, step) in plan.steps.enumerated() {
            do {
                try Task.checkCancellation()
                let resolved = try artifactSnapshot.resolve(step)
                let inputs = try resolved.map { artifact -> ArtifactRef in
                    guard let current = artifact.refreshedFromDisk() else {
                        throw KioFailure.invalidInput("One of the selected files is no longer available. Add it again and retry.")
                    }
                    return current
                }
                let status = Self.status(for: step.operation, inputCount: inputs.count)
                publishExecution(for: plan, status: .running, stepIndex: stepIndex, operation: step.operation,
                                 agent: step.owner, text: status, completed: stepIndex, total: plan.steps.count)
                append(step.owner.name, status)
                if let remote {
                    if stepIndex > 0, plan.steps[stepIndex - 1].owner != step.owner {
                        await LocalRelayManager.shared.sendReply(type: "progress", text: "I'll hand this to \(step.owner.name).", taskID: remote.taskID, artifactURL: nil, to: remote.phoneID, speaker: "Kio", agent: AgentID.kio.rawValue)
                    }
                    await LocalRelayManager.shared.sendReply(type: "progress", text: status, taskID: remote.taskID, artifactURL: nil, to: remote.phoneID, speaker: step.owner.name, agent: step.owner.rawValue)
                }
                if step.operation == .moveFiles, !(await confirmMove(inputs)) {
                    publishExecution(for: plan, status: .cancelled, stepIndex: stepIndex, operation: step.operation,
                                     agent: step.owner, text: "Move canceled. No files were moved.", completed: stepIndex, total: plan.steps.count,
                                     output: activeOutput)
                    append("Kio", "Move canceled. No files were moved.")
                    return nil
                }
                let outputs = try await executor.execute(step, inputs: inputs)
                guard !outputs.isEmpty, outputs.allSatisfy({ FileManager.default.fileExists(atPath: $0.fileURL.path) && $0.sizeBytes > 0 }) else {
                    throw KioFailure.verification("Kio could not verify the result file.")
                }
                artifactSnapshot.record(outputs, for: step)
                finalOutputs = outputs
                lastOperation = step.operation
                activeOutput = outputs.last
                ConversationPersistence.saveActiveOutput(activeOutput)
                publishExecution(for: plan, status: .running, stepIndex: stepIndex, operation: step.operation,
                                 agent: step.owner, text: "Finished step \(stepIndex + 1) of \(plan.steps.count).",
                                 completed: stepIndex + 1, total: plan.steps.count, output: outputs.last)
                for output in outputs {
                    let message = output.verificationNote.map { "\($0)\n\(output.displayName)" } ?? "Done. \(output.displayName)"
                    append("Kio", message, artifact: output)
                }
            } catch is CancellationError {
                publishExecution(for: plan, status: .cancelled, stepIndex: stepIndex, operation: step.operation,
                                 agent: step.owner, text: "Stopped.", completed: stepIndex, total: plan.steps.count,
                                 output: activeOutput)
                append("Kio", "Stopped. Any completed copies remain available; original files are unchanged.")
                return nil
            } catch {
                let message = error.localizedDescription
                latestError = message
                publishExecution(for: plan, status: .failed, stepIndex: stepIndex, operation: step.operation,
                                 agent: step.owner, text: message, completed: stepIndex, total: plan.steps.count,
                                 output: activeOutput, failure: message)
                append(step.owner.name, "I couldn't finish that: \(message)")
                return nil
            }
        }
        publishExecution(for: plan, status: .completed, stepIndex: nil, operation: plan.steps.last?.operation,
                         agent: plan.steps.last?.owner ?? .kio, text: "Done.", completed: plan.steps.count,
                         total: plan.steps.count, output: activeOutput)
        return finalOutputs
    }

    private func publishExecution(for plan: TaskPlan, status: TaskExecutionStatus, stepIndex: Int? = nil,
                                  operation: ToolOperation? = nil, agent: AgentID = .kio, text: String,
                                  completed: Int = 0, total: Int = 0, output: ArtifactRef? = nil,
                                  failure: String? = nil) {
        executionState = TaskExecutionState(taskID: plan.id, plan: plan, currentStepIndex: stepIndex,
                                            currentOperation: operation, activeAgent: agent, status: status,
                                            statusText: text, completedStepCount: completed,
                                            totalStepCount: total, latestOutput: output, failureMessage: failure)
    }

    func clearHistory() {
        attachments = []
        activeOutput = nil
        lastOperation = nil
        lastPlan = nil
        ConversationPersistence.saveLastPlan(nil)
        executionState = nil
        conversation = [ConversationItem(speaker: "Kio", message: "History cleared. Add a file whenever you're ready.", artifact: nil)]
        ConversationPersistence.clear()
        ConversationPersistence.append(conversation[0], operation: nil)
    }

    private func append(_ speaker: String, _ message: String, artifact: ArtifactRef? = nil) {
        let operation = (speaker == "You" || speaker == "Phone") ? nil : lastOperation
        let item = ConversationItem(speaker: speaker, message: message, artifact: artifact, operation: operation)
        conversation.append(item)
        ConversationPersistence.append(item, operation: operation)
    }

    private static func status(for operation: ToolOperation, inputCount: Int) -> String {
        switch operation {
        case .mergePDFs: "Merging \(inputCount) PDFs."
        case .combineMixedPDFInputs: "Pip is combining PDFs and images in their selected order."
        case .removePDFPages: "Editing PDF pages."
        case .removeBlankPDFPages: "Checking each PDF page and removing visually blank pages."
        case .splitPDF: "Splitting the PDF into one-page files."
        case .extractPDFPages: "Extracting the selected PDF pages."
        case .reorderPDFPages: "Reordering all pages in the requested order."
        case .rotatePDFPages: "Rotating PDF pages."
        case .extractPDFText: "Extracting selectable PDF text."
        case .ocrPDFText: "Reading scanned PDF pages with on-device OCR."
        case .inspectPDF: "Inspecting the PDF."
        case .searchPDFText: "Pip is searching selectable PDF text and keeping page references."
        case .imagesToPDF: "Putting the images into a PDF."
        case .resizeImage: "Resizing the image."
        case .batchResizeImages: "Pixel is resizing the selected images into verified copies."
        case .convertImage: "Converting the image."
        case .batchConvertImages: "Pixel is converting each selected image into a verified copy."
        case .compareImages: "Pixel is comparing the two images using a small-image luminance signature."
        case .findSimilarImages: "Pixel is looking for approximate visual matches among these images."
        case .removeImageBackground: "Pixel is asking Vision to separate the foreground and create a transparent PNG."
        case .rotateImage: "Rotating the image."
        case .inspectImage: "Inspecting the image."
        case .cropImage: "Cropping the selected image area."
        case .smartCropImage: "Pixel is framing the main subject with on-device Vision."
        case .compressImage: "Creating and checking a smaller image copy."
        case .removeImageMetadata: "Removing embedded image metadata."
        case .imageContactSheet: "Arranging the selected images into a contact sheet."
        case .renameFile: "Making a conflict-safe copy with the requested name."
        case .batchRename: "Making conflict-safe renamed copies."
        case .copyFiles: "Copying files into the selected folder and checking each copy."
        case .moveFiles: "Moving the selected files into the chosen folder."
        case .createFolder: "Creating a new folder in the chosen location."
        case .findDuplicates: "Comparing file hashes to find exact duplicates."
        case .findRecent: "Clerk is listing recent files in the selected folder."
        case .findByName: "Clerk is matching the requested words against selected file names."
        case .organizeByType: "Sorting verified file copies into type folders."
        case .organizeByDate: "Sorting verified file copies into date folders."
        case .organizeByModulePattern: "Clerk is grouping verified copies by their filename prefix."
        case .organizeDownloads: "Clerk is organizing verified copies from the selected Downloads folder."
        case .createArchive: "Creating a ZIP archive."
        case .inspectArchive: "Listing the ZIP contents."
        case .extractZip: "Checking ZIP paths and extracting into a new folder."
        case .compressPDF: "Compressing a readable PDF copy."
        case .extractAudio: "Extracting the audio track."
        case .transcribeAudio: "Echo is transcribing with Apple's on-device speech recognizer."
        case .generateSubtitles: "Echo is generating SRT and VTT subtitles on this Mac."
        case .inspectMedia: "Inspecting the video's tracks and duration."
        case .thumbnailVideo: "Capturing a frame from the video."
        case .trimVideo: "Trimming a copy of the video."
        case .extractMediaClip: "Echo is extracting the requested video clip."
        case .convertAudio: "Echo is converting a copy to M4A with native Apple media tools."
        case .resizeVideo: "Resizing the video with a native MP4 preset."
        case .transcodeVideo: "Converting a copy to MP4."
        case .compressVideo: "Checking smaller native MP4 export presets."
        case .summarizeText: "Scribe is summarizing the text on this Mac."
        case .rewriteText: "Scribe is rewriting the text on this Mac."
        case .proofreadText: "Scribe is proofreading the text on this Mac."
        case .translateText: "Scribe is translating the text on this Mac."
        case .keyPointsText: "Scribe is extracting key points on this Mac."
        case .actionItemsText: "Scribe is finding stated action items on this Mac."
        case .toMarkdownText: "Scribe is converting the text to Markdown on this Mac."
        case .compareText: "Scribe is comparing the documents on this Mac."
        case .explainText: "Scribe is preparing a plain-language explanation on this Mac."
        case .inspectData: "Table is inspecting the file's rows and columns."
        case .mergeData: "Table is merging compatible CSV/TSV/JSON tables."
        case .deduplicateData: "Table is removing repeated rows."
        case .sortData: "Table is sorting rows by the chosen column."
        case .filterData: "Table is filtering rows that match the requested value."
        case .selectColumns: "Table is selecting the requested columns."
        case .renameColumns: "Table is renaming the selected column."
        case .reorderColumns: "Table is arranging columns in the requested order."
        case .dataStatistics: "Table is calculating row, missing-value, frequency, and numeric statistics."
        case .csvToJSON: "Table is converting CSV/TSV rows to JSON."
        case .jsonToCSV: "Table is converting JSON table data to CSV."
        case .normalizeData: "Table is trimming surrounding whitespace from table cells."
        case .compareData: "Table is comparing the two tables."
        case .importXLSX: "Table is importing bounded workbook values into a CSV copy."
        case .fetchURL: "Scout is fetching the public page and extracting readable text."
        case .extractWebLinks: "Scout is listing the links on this page without visiting them."
        case .researchOpenSources: "Scout is searching Crossref and Europe PMC for source records."
        case .ocrImage: "Lens is reading text and keeping its source positions and confidence."
        case .extractStructuredText: "Lens is extracting visible text from the image."
        case .extractImageTable: "Lens is grouping pictured table rows and retaining its OCR evidence."
        case .extractReceipt: "Lens is reading receipt fields and leaving anything uncertain blank."
        case .explainCode: "Patch is preparing a local explanation. It will not run or change the source file."
        case .proposePatch: "Patch is preparing a separate proposed copy and reviewable diff. The original stays untouched."
        case .formatJSON: "Patch is formatting a new JSON copy and checking that it remains valid."
        }
    }

    private func recentTaskArtifactEntries() -> [ArtifactContextEntry] {
        var reversed: [ArtifactContextEntry] = []
        for item in conversation.reversed() {
            guard let artifact = item.artifact else {
                if !reversed.isEmpty { break }
                continue
            }
            reversed.append(ArtifactContextEntry(artifact: artifact, operation: item.operation,
                                                 speaker: item.speaker, createdAt: item.createdAt))
        }
        return reversed.reversed()
    }

    private func confirmMove(_ inputs: [ArtifactRef]) async -> Bool {
        guard let destination = inputs.last, destination.kind == .folder else { return false }
        let files = Array(inputs.dropLast())
        guard !files.isEmpty else { return false }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Move \(files.count) file\(files.count == 1 ? "" : "s")?"
            let preview = files.prefix(8).map { "• \($0.displayName)" }.joined(separator: "\n")
            let remaining = files.count > 8 ? "\n… and \(files.count - 8) more" : ""
            alert.informativeText = "Destination: \(destination.displayName)\n\n\(preview)\(remaining)\n\nThis changes the selected files' locations."
            alert.addButton(withTitle: "Move Files")
            alert.addButton(withTitle: "Cancel")
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            } else {
                continuation.resume(returning: alert.runModal() == .alertFirstButtonReturn)
            }
        }
    }

    private static func safeFileName(_ value: String?) -> String {
        let name = URL(fileURLWithPath: value ?? "Phone attachment").lastPathComponent
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let clean = name.components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        return clean.isEmpty ? "attachment" : String(clean.prefix(96))
    }

    private static func webURLs(in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\bhttps?://[^\s<>()\[\]{}]+"#) else { return [] }
        let source = value as NSString
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            guard match.range.location != NSNotFound else { return nil }
            let candidate = source.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:)'\"]}»”’"))
            return candidate.isEmpty ? nil : candidate
        }
    }

    private static func removingWebURLs(from value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\bhttps?://[^\s<>()\[\]{}]+"#) else { return value }
        return regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: " ")
    }

    private static func researchTopic(in request: String) -> String? {
        let patterns = [
            #"(?i)^\s*(?:please\s+)?(?:find|search|look\s+up|discover)\s+(?:me\s+)?(?:some\s+)?(?:open[- ]source\s+|academic\s+|research\s+)*(?:papers?|studies|literature|sources|references)\s+(?:about|on|for|regarding|into)\s+(.+?)\s*[.!?]?\s*$"#,
            #"(?i)^\s*research\s+(?:on|about|into)\s+(.+?)\s*[.!?]?\s*$"#,
            #"(?i)^\s*research\s+(?:papers?|studies)\s+(?:about|on|for)\s+(.+?)\s*[.!?]?\s*$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)),
                  let range = Range(match.range(at: 1), in: request) else { continue }
            var topic = String(request[range])
            if let suffix = try? NSRegularExpression(pattern: #"(?i)\s+(?:and|then)\s+(?:summari[sz]e|review|compare)\b.*$"#) {
                topic = suffix.stringByReplacingMatches(in: topic, range: NSRange(topic.startIndex..., in: topic), withTemplate: "")
            }
            topic = topic.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
            guard (3...512).contains(topic.count), Self.webURLs(in: topic).isEmpty else { return nil }
            return topic
        }
        return nil
    }
}
