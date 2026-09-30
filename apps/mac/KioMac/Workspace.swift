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

    init(id: UUID = UUID(), speaker: String, message: String, artifact: ArtifactRef?) {
        self.id = id
        self.speaker = speaker
        self.message = message
        self.artifact = artifact
    }
}

@MainActor
final class KioWorkspace: ObservableObject {
    private struct PendingRemoteRequest {
        let phoneID: String
        let payload: RelayPayload
        let stagedAttachmentURL: URL?
    }

    static let shared = KioWorkspace()

    @Published private(set) var attachments: [ArtifactRef] = []
    @Published private(set) var conversation: [ConversationItem]
    @Published private(set) var isWorking = false
    @Published private(set) var activeOutput: ArtifactRef?
    @Published private(set) var latestError: String?

    private var lastOperation: ToolOperation?
    private var runningTask: Task<Void, Never>?
    private var pendingRemoteRequests: [PendingRemoteRequest] = []
    private let planner = FastPathPlanner()
    private let fastResponseResolver = FastPathResponseResolver()
    private let executor = ToolExecutor()

    private init() {
        if let restored = ConversationPersistence.restore() {
            conversation = restored.items
            activeOutput = restored.activeOutput
            lastOperation = restored.operation
        } else {
            conversation = [ConversationItem(speaker: "Kio", message: "Drop in a file and tell me what you want done. Kio processes files on this Mac. You can install an optional 1.72 GB local model in Settings for broader request planning.", artifact: nil)]
        }
    }

    func addURLs(_ urls: [URL]) {
        let known = Set(attachments.map { $0.fileURL.standardizedFileURL })
        var added: [ArtifactRef] = []
        for url in urls where !known.contains(url.standardizedFileURL) {
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

    func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id } }
    func clearAttachments() { attachments.removeAll() }

    func submit(_ rawRequest: String) {
        submit(rawRequest, remote: nil)
    }

    func receiveRemoteRequest(from phoneID: String, payload: RelayPayload, attachmentData: Data?) {
        guard payload.type == "request", let taskID = payload.taskID else { return }
        guard payload.text.count <= 2_000, !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Task { await LocalRelayManager.shared.sendReply(type: "error", text: "That request is empty or too long to send safely.", taskID: taskID, artifactURL: nil, to: phoneID) }
            return
        }
        if payload.attachmentID == nil, let answer = fastResponseResolver.response(to: payload.text) {
            append("Phone", payload.text)
            append("Kio", answer)
            Task { await LocalRelayManager.shared.sendReply(type: "result", text: answer, taskID: taskID, artifactURL: nil, to: phoneID) }
            return
        }
        var stagedAttachmentURL: URL?
        do {
            if payload.attachmentID != nil {
                guard let data = attachmentData, data.count <= 50 * 1024 * 1024, data.count == payload.artifactSize else { throw KioFailure.invalidInput("This phone attachment could not be verified.") }
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let inbox = support.appendingPathComponent("Kio/RelayInbox", isDirectory: true)
                try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                let fileURL = inbox.appendingPathComponent(UUID().uuidString + "-" + Self.safeFileName(payload.artifactName))
                try data.write(to: fileURL, options: .atomic)
                stagedAttachmentURL = fileURL
            }
            if isWorking {
                guard pendingRemoteRequests.count < 3 else { throw KioFailure.invalidInput("The Mac already has three phone requests waiting. Try again when one finishes.") }
                pendingRemoteRequests.append(PendingRemoteRequest(phoneID: phoneID, payload: payload, stagedAttachmentURL: stagedAttachmentURL))
                append("Kio", "Added your phone request to the Mac queue.")
                Task { await LocalRelayManager.shared.sendReply(type: "progress", text: "Added to the Mac queue. It will start after the current task.", taskID: taskID, artifactURL: nil, to: phoneID) }
                return
            }
            startRemoteRequest(from: phoneID, payload: payload, stagedAttachmentURL: stagedAttachmentURL)
        } catch {
            if let stagedAttachmentURL { try? FileManager.default.removeItem(at: stagedAttachmentURL) }
            append("Kio", "I couldn't receive that phone attachment: \(error.localizedDescription)")
            Task { await LocalRelayManager.shared.sendReply(type: "error", text: error.localizedDescription, taskID: taskID, artifactURL: nil, to: phoneID) }
        }
    }

    private func startRemoteRequest(from phoneID: String, payload: RelayPayload, stagedAttachmentURL: URL?) {
        guard let taskID = payload.taskID else { return }
        var inputURL: URL?
        do {
            if let stagedAttachmentURL {
                defer { try? FileManager.default.removeItem(at: stagedAttachmentURL) }
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Kio", isDirectory: true)
                try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
                let destination = downloads.appendingPathComponent("Phone-\(UUID().uuidString)-\(Self.safeFileName(payload.artifactName))")
                try FileManager.default.copyItem(at: stagedAttachmentURL, to: destination)
                attachments.append(try ArtifactRef.inspect(destination))
                inputURL = destination
            }
            submit(payload.text, remote: (phoneID, taskID, inputURL))
        } catch {
            if let inputURL { try? FileManager.default.removeItem(at: inputURL) }
            append("Kio", "I couldn't prepare the phone request: \(error.localizedDescription)")
            Task { await LocalRelayManager.shared.sendReply(type: "error", text: error.localizedDescription, taskID: taskID, artifactURL: nil, to: phoneID) }
        }
    }

    private func submit(_ rawRequest: String, remote: (phoneID: String, taskID: String, inputURL: URL?)?) {
        let request = rawRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isWorking else { return }
        append(remote == nil ? "You" : "Phone", request)
        latestError = nil
        let context = PlanningContext(activeOutput: activeOutput, previousOperation: lastOperation)
        let fastPlan = planner.plan(request: request, artifacts: attachments, context: context)
        let planningArtifacts = attachments.isEmpty ? (activeOutput.map { [$0] } ?? []) : attachments
        isWorking = true
        runningTask = Task {
            defer {
                isWorking = false
                runningTask = nil
                if let inputURL = remote?.inputURL {
                    try? FileManager.default.removeItem(at: inputURL)
                    attachments.removeAll { $0.fileURL.standardizedFileURL == inputURL.standardizedFileURL }
                }
                if !pendingRemoteRequests.isEmpty {
                    let next = pendingRemoteRequests.removeFirst()
                    startRemoteRequest(from: next.phoneID, payload: next.payload, stagedAttachmentURL: next.stagedAttachmentURL)
                }
            }
            var plan = fastPlan
            if plan.steps.isEmpty {
                guard LocalModelManager.shared.isInstalled else {
                    let message = plan.clarification ?? "I need a clearer instruction for that."
                    append("Kio", "\(message) A local model can plan other registered workflows after you prepare it in Settings.")
                    if let remote { await LocalRelayManager.shared.sendReply(type: "error", text: message, taskID: remote.taskID, artifactURL: nil, to: remote.phoneID) }
                    return
                }
                append("Kio", "Planning with the local model…")
                do {
                    guard let modelPlan = try await LocalModelManager.shared.plan(request: request, artifacts: planningArtifacts) else {
                        append("Kio", "I couldn't verify a safe tool plan for that request. Try adding a little more detail.")
                        if let remote { await LocalRelayManager.shared.sendReply(type: "error", text: "I couldn't verify a safe tool plan for that request. Add a little more detail and try again.", taskID: remote.taskID, artifactURL: nil, to: remote.phoneID) }
                        return
                    }
                    plan = modelPlan
                } catch is CancellationError {
                    append("Kio", "Stopped before making changes.")
                    if let remote { await LocalRelayManager.shared.sendReply(type: "error", text: "Stopped before making changes.", taskID: remote.taskID, artifactURL: nil, to: remote.phoneID) }
                    return
                } catch {
                    latestError = error.localizedDescription
                    append("Kio", "The local model couldn't plan this safely: \(error.localizedDescription)")
                    if let remote { await LocalRelayManager.shared.sendReply(type: "error", text: "The local model couldn't plan this safely: \(error.localizedDescription)", taskID: remote.taskID, artifactURL: nil, to: remote.phoneID) }
                    return
                }
            }
            guard !plan.steps.isEmpty else {
                let message = plan.clarification ?? "I need a clearer instruction for that."
                append("Kio", message)
                if let remote { await LocalRelayManager.shared.sendReply(type: "error", text: message, taskID: remote.taskID, artifactURL: nil, to: remote.phoneID) }
                return
            }
            if let remote { await LocalRelayManager.shared.sendReply(type: "progress", text: "Your request is running on your Mac.", taskID: remote.taskID, artifactURL: nil, to: remote.phoneID) }
            let result = await execute(plan)
            guard let remote else { return }
            if let result {
                await LocalRelayManager.shared.sendReply(type: "result", text: "Done. \(result.displayName) is ready.", taskID: remote.taskID, artifactURL: result.fileURL, to: remote.phoneID)
            } else {
                let message = latestError ?? "Kio stopped before creating a result."
                await LocalRelayManager.shared.sendReply(type: "error", text: message, taskID: remote.taskID, artifactURL: nil, to: remote.phoneID)
            }
        }
    }

    func cancelCurrentTask() { runningTask?.cancel() }

    private func execute(_ plan: TaskPlan) async -> ArtifactRef? {
        var outputsByStep: [UUID: [ArtifactRef]] = [:]
        for step in plan.steps {
            do {
                try Task.checkCancellation()
                let inputs: [ArtifactRef]
                switch step.source {
                case .artifacts(let ids):
                    let all = Dictionary((attachments + (activeOutput.map { [$0] } ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
                    guard ids.allSatisfy({ all[$0] != nil }) else { throw KioFailure.invalidInput("One of the selected files is no longer available. Add it again and retry.") }
                    inputs = ids.compactMap { all[$0] }
                case .previousStep(let id):
                    guard let previous = outputsByStep[id] else { throw KioFailure.invalidInput("A previous operation did not produce an output.") }
                    inputs = previous
                }
                append(step.owner.name, Self.status(for: step.operation, inputCount: inputs.count))
                let outputs = try await executor.execute(step, inputs: inputs)
                guard !outputs.isEmpty, outputs.allSatisfy({ FileManager.default.fileExists(atPath: $0.fileURL.path) && $0.sizeBytes > 0 }) else {
                    throw KioFailure.verification("Kio could not verify the result file.")
                }
                outputsByStep[step.id] = outputs
                lastOperation = step.operation
                activeOutput = outputs.last
                attachments.removeAll()
                for output in outputs {
                    let message = output.verificationNote.map { "\($0)\n\(output.displayName)" } ?? "Done. \(output.displayName)"
                    append("Kio", message, artifact: output)
                }
            } catch is CancellationError {
                append("Kio", "Stopped. Any completed copies remain available; original files are unchanged.")
                return nil
            } catch {
                let message = error.localizedDescription
                latestError = message
                append(step.owner.name, "I couldn't finish that: \(message)")
                return nil
            }
        }
        return activeOutput
    }

    func clearHistory() {
        attachments = []
        activeOutput = nil
        lastOperation = nil
        conversation = [ConversationItem(speaker: "Kio", message: "History cleared. Add a file whenever you're ready.", artifact: nil)]
        ConversationPersistence.clear()
        ConversationPersistence.append(conversation[0], operation: nil)
    }

    private func append(_ speaker: String, _ message: String, artifact: ArtifactRef? = nil) {
        let item = ConversationItem(speaker: speaker, message: message, artifact: artifact)
        conversation.append(item)
        ConversationPersistence.append(item, operation: lastOperation)
    }

    private static func status(for operation: ToolOperation, inputCount: Int) -> String {
        switch operation {
        case .mergePDFs: "Merging \(inputCount) PDFs."
        case .removePDFPages: "Editing PDF pages."
        case .imagesToPDF: "Putting the images into a PDF."
        case .resizeImage: "Resizing the image."
        case .convertImage: "Converting the image."
        case .batchRename: "Making conflict-safe renamed copies."
        case .createArchive: "Creating a ZIP archive."
        case .compressPDF: "Compressing a readable PDF copy."
        case .extractAudio: "Extracting the audio track."
        }
    }

    private static func safeFileName(_ value: String?) -> String {
        let name = URL(fileURLWithPath: value ?? "Phone attachment").lastPathComponent
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let clean = name.components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        return clean.isEmpty ? "attachment" : String(clean.prefix(96))
    }
}
