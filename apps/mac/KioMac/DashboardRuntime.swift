import AppKit
import Combine
import Foundation
import KioCore
import KioModel
import KioTools
import UniformTypeIdentifiers

@MainActor
final class NotchEventCoordinator: ObservableObject {
    static let shared = NotchEventCoordinator()
    @Published private(set) var current: NotchAmbientEvent?
    private var queue = NotchEventQueue()
    private var dismissalTask: Task<Void, Never>?
    private init() {}

    func emit(_ kind: NotchEventKind, title: String, duration: Duration = .seconds(4), userEnabledNewsAlert: Bool = false) {
        let event = NotchAmbientEvent(kind: kind, title: title)
        let previousCurrent = queue.current?.id
        guard queue.enqueue(event, allowNewsAlert: userEnabledNewsAlert) else { return }
        current = queue.current
        guard queue.current?.id != previousCurrent else { return }
        dismissalTask?.cancel()
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissalTask?.cancel(); dismissalTask = nil
        queue.dismissCurrent(); current = queue.current
        if current != nil {
            dismissalTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.dismiss()
            }
        }
    }
}

@MainActor
final class KioDashboardModel: ObservableObject {
    static let shared = KioDashboardModel()
    @Published var selectedSpace: DashboardSpace {
        didSet { UserDefaults.standard.set(selectedSpace.rawValue, forKey: "kio.dashboard.lastSpace") }
    }
    @Published private(set) var attachments: [ArtifactRef] = []
    @Published var commandText = ""
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var outputs: [ArtifactRef] = []
    @Published private(set) var sessions: [DeveloperSession] = []
    @Published private(set) var clipboardEntries: [ClipboardEntry] = []
    @Published private(set) var newsItems: [NewsItem] = []
    @Published private(set) var reelInfo: ReelInspectionInfo?
    @Published private(set) var isInspectingReel = false
    @Published var cueInitialText = ""
    @Published private(set) var cueIsActive = false

    private let sessionStore = DeveloperSessionStore()
    private let clipboardStore = ClipboardStore()
    private let newsStore = NewsStore()
    private var clipboardTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var securityScopeURLs: [URL] = []

    private init() {
        selectedSpace = DashboardSpace(rawValue: UserDefaults.standard.string(forKey: "kio.dashboard.lastSpace") ?? "kio") ?? .kio
        Task { await refreshSnapshots() }
        Task { try? await clipboardStore.setMaximumEntries(UserDefaults.standard.integer(forKey: "kio.clipboard.maximumEntries") == 0 ? 200 : UserDefaults.standard.integer(forKey: "kio.clipboard.maximumEntries")) }
        startClipboardMonitor()
        startSessionInboxMonitor()
    }

    func select(_ space: DashboardSpace) { selectedSpace = space }

    func badge(for space: DashboardSpace) -> String? {
        let count: Int
        switch space {
        case .kio: return nil
        case .sessions: count = sessions.filter(\.unreadEvent).count
        case .clipboard: count = clipboardEntries.count
        case .news: count = newsItems.count
        }
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    func addURLs(_ urls: [URL]) {
        for url in urls {
            guard url.isFileURL, let scoped = try? ArtifactRef.inspect(url) else { continue }
            if scoped.kind == .other { statusMessage = "Convert supports images, audio, video, and PDF files."; continue }
            if url.startAccessingSecurityScopedResource() { securityScopeURLs.append(url) }
            if !attachments.contains(where: { $0.fileURL.standardizedFileURL == url.standardizedFileURL }) { attachments.append(scoped) }
        }
        outputs = []; statusMessage = nil
    }

    func addMediaURL(_ rawValue: String) {
        do {
            let artifact = try ReelURLReference.makeArtifact(rawValue)
            selectedSpace = .kio; attachments = [artifact]; reelInfo = nil
            Task { await inspectReel() }
        } catch { statusMessage = error.localizedDescription }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
        if attachments.isEmpty { releaseSecurityScopes() }
        outputs = []; statusMessage = nil
    }

    func clearAttachments() {
        attachments.removeAll(); outputs.removeAll(); reelInfo = nil; statusMessage = nil
        releaseSecurityScopes()
    }

    func performConvert(_ request: String? = nil) async {
        guard !attachments.isEmpty, !isWorking else { return }
        let value = request ?? commandText
        guard let intent = ConvertRequestParser.parse(value, inputs: attachments) else {
            statusMessage = "Choose an output format or drop files to see conversion options."; return
        }
        if case .unsupported(let message) = intent { statusMessage = message; return }
        isWorking = true; outputs = []; statusMessage = intent.operationTitle
        defer { isWorking = false; releaseSecurityScopes() }
        do {
            let executor = ToolExecutor()
            var result: [ArtifactRef] = []
            switch intent {
            case .image(let format, let width, let maximumBytes):
                var working = attachments
                if let width {
                    working = try await executor.execute(TaskStep(operation: .batchResizeImages,
                        source: .artifacts(working.map(\.id)), arguments: .imageResize(width: width)), inputs: working)
                }
                if let maximumBytes {
                    guard format == nil || ["jpeg", "jpg"].contains(format?.lowercased() ?? "") else {
                        throw KioFailure.unsupported("The target-size compressor creates JPEG files. Choose JPEG for a target-size image conversion.")
                    }
                    working = try await executor.execute(TaskStep(operation: .compressImage,
                        source: .artifacts(working.map(\.id)), arguments: .imageCompression(maxBytes: maximumBytes)), inputs: working)
                } else if let format {
                    working = try await executor.execute(TaskStep(operation: .batchConvertImages,
                        source: .artifacts(working.map(\.id)), arguments: .imageConvert(format: format)), inputs: working)
                } else if width == nil {
                    statusMessage = "Choose JPEG, PNG, HEIC, WebP, or TIFF."; return
                }
                result = working
            case .pdfCompression(let maximumBytes):
                if attachments.count == 1 {
                    result = try await executor.execute(TaskStep(operation: .compressPDF,
                        source: .artifacts(attachments.map(\.id)), arguments: .pdfCompression(maxBytes: maximumBytes)), inputs: attachments)
                } else {
                    let merged = try await executor.execute(TaskStep(operation: .mergePDFs,
                        source: .artifacts(attachments.map(\.id))), inputs: attachments)
                    if let mergedPDF = merged.first, maximumBytes != nil {
                        result = try await executor.execute(TaskStep(operation: .compressPDF,
                            source: .artifacts([mergedPDF.id]), arguments: .pdfCompression(maxBytes: maximumBytes)), inputs: [mergedPDF])
                    } else {
                        result = merged
                    }
                }
            case .imagesToPDF:
                result = try await executor.execute(TaskStep(operation: .imagesToPDF,
                    source: .artifacts(attachments.map(\.id))), inputs: attachments)
            case .mergePDFs:
                result = try await executor.execute(TaskStep(operation: .mergePDFs,
                    source: .artifacts(attachments.map(\.id))), inputs: attachments)
            case .audio(let format), .extractAudio(let format):
                result = try await executor.execute(TaskStep(operation: .convertAudio,
                    source: .artifacts(attachments.map(\.id)), arguments: .audioConvert(format: format)), inputs: attachments)
            case .video(let format, let width, let maximumBytes):
                var working = attachments
                if let width {
                    working = try await executor.execute(TaskStep(operation: .resizeVideo,
                        source: .artifacts(working.map(\.id)), arguments: .mediaResize(width: width)), inputs: working)
                }
                if let maximumBytes {
                    working = try await executor.execute(TaskStep(operation: .compressVideo,
                        source: .artifacts(working.map(\.id)), arguments: .mediaCompression(maxBytes: maximumBytes)), inputs: working)
                } else if let format {
                    working = try await executor.execute(TaskStep(operation: .transcodeVideo,
                        source: .artifacts(working.map(\.id)), arguments: .videoConvert(format: format)), inputs: working)
                }
                result = working
            case .unsupported: break
            }
            outputs = result; statusMessage = result.isEmpty ? "No output was created." : "Done · \(result.count) file\(result.count == 1 ? "" : "s")"
            NotchEventCoordinator.shared.emit(.conversionComplete, title: result.count == 1 ? "File ready" : "\(result.count) files ready")
        } catch {
            statusMessage = error.localizedDescription
            NotchEventCoordinator.shared.emit(.conversionFailed, title: "Convert failed")
        }
        commandText = ""
        await refreshSnapshots()
    }

    func inspectReel() async {
        guard let input = attachments.first(where: { $0.kind == .url }), !isInspectingReel else { return }
        isInspectingReel = true; statusMessage = "Inspecting media…"
        defer { isInspectingReel = false }
        do {
            let output = try await ToolExecutor().execute(TaskStep(operation: .inspectRemoteMedia,
                source: .artifacts([input.id])), inputs: [input])
            guard let infoArtifact = output.first else { throw KioFailure.verification("Reel returned no media details.") }
            reelInfo = try ReelInspectionStore.readInfo(from: infoArtifact)
            statusMessage = nil
        } catch { statusMessage = error.localizedDescription }
    }

    func downloadReelVideo(quality: String, format: String) async {
        await runReelDownload(operation: .downloadRemoteVideo, quality: quality, format: format)
    }
    func downloadReelAudio(format: String) async {
        await runReelDownload(operation: .downloadRemoteAudio, quality: nil, format: format)
    }
    func downloadReelSubtitles() async {
        await runReelDownload(operation: .downloadRemoteSubtitles, quality: nil, format: nil)
    }
    private func runReelDownload(operation: ToolOperation, quality: String?, format: String?) async {
        guard let input = attachments.first(where: { $0.kind == .url }), !isWorking else { return }
        isWorking = true; statusMessage = "Downloading…"
        defer { isWorking = false }
        do {
            let result = try await ToolExecutor().execute(TaskStep(operation: operation,
                source: .artifacts([input.id]), arguments: .remoteMedia(quality: quality, format: format)), inputs: [input])
            outputs = result; statusMessage = result.first.map { "Done · \($0.displayName)" } ?? "Download finished."
            NotchEventCoordinator.shared.emit(.reelComplete, title: "Reel finished")
        } catch {
            statusMessage = error.localizedDescription
            NotchEventCoordinator.shared.emit(.reelFailed, title: "Reel failed")
        }
        await refreshSnapshots()
    }

    func startCue(with text: String? = nil) {
        if let text { cueInitialText = text }
        selectedSpace = .kio
    }
    func cueActiveChanged(_ value: Bool) { cueIsActive = value }

    func refreshSnapshots() async {
        sessions = await sessionStore.snapshot()
        clipboardEntries = await clipboardStore.search()
        newsItems = await newsStore.items()
    }

    func markSessionRead(_ id: String) { Task { try? await sessionStore.markRead(sessionID: id); sessions = await sessionStore.snapshot() } }
    func pinClipboard(_ id: UUID) { Task { try? await clipboardStore.togglePin(id); clipboardEntries = await clipboardStore.search() } }
    func deleteClipboard(_ id: UUID) { Task { try? await clipboardStore.delete(id); clipboardEntries = await clipboardStore.search() } }
    func clearClipboard() { Task { try? await clipboardStore.clear(); clipboardEntries = [] } }
    func setClipboardMaximum(_ value: Int) async { try? await clipboardStore.setMaximumEntries(value); clipboardEntries = await clipboardStore.search() }

    func copyClipboardEntry(_ entry: ClipboardEntry) {
        NSPasteboard.general.clearContents()
        switch entry.payload {
        case .text(let text): NSPasteboard.general.setString(text, forType: .string)
        case .fileURLs(let urls): NSPasteboard.general.writeObjects(urls as [NSURL])
        case .image(let url, _, _):
            if let data = try? Data(contentsOf: url) {
                let board = NSPasteboard.general
                let png = NSPasteboard.PasteboardType("public.png")
                board.declareTypes([png], owner: nil)
                board.setData(data, forType: png)
            }
        }
    }

    func refreshNews() async {
        guard UserDefaults.standard.object(forKey: "kio.news.enabled") as? Bool ?? true else { return }
        do {
            let alerts = try await newsStore.refresh()
            newsItems = await newsStore.items()
            for item in alerts.prefix(1) {
                NotchEventCoordinator.shared.emit(.newsAlert, title: item.headline, userEnabledNewsAlert: true)
            }
        } catch { statusMessage = "News couldn't refresh: \(error.localizedDescription)" }
    }

    func saveNewsPreferences(topics: [String], sources: [NewsFeedSource], alertTopics: Set<String>) async throws {
        try await newsStore.configure(sources: sources, topics: topics, alertTopics: alertTopics)
        await refreshNews()
    }

    func newsConfiguration() async -> NewsConfiguration { await newsStore.configuration() }

    private func startClipboardMonitor() {
        clipboardTask?.cancel()
        clipboardTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, let self else { return }
                self.capturePasteboardIfNeeded()
            }
        }
    }

    private func capturePasteboardIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "kio.clipboard.enabled") else { return }
        let board = NSPasteboard.general
        guard board.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = board.changeCount
        let types = board.types?.map(\.rawValue) ?? []
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let excluded = Set(UserDefaults.standard.stringArray(forKey: "kio.clipboard.excludedBundleIDs") ?? [])
        guard source != Bundle.main.bundleIdentifier else { return }
        guard ClipboardPrivacyPolicy.shouldCapture(types: types, sourceBundleID: source, excludedBundleIDs: excluded) else { return }
        Task { @MainActor in
            do {
                let payload: ClipboardPayload
                if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                    payload = .fileURLs(Array(urls.prefix(32)))
                } else if let tiff = board.data(forType: .tiff), tiff.count <= 32_000_000,
                          let image = NSImage(data: tiff),
                          let representation = NSBitmapImageRep(data: tiff),
                          let data = representation.representation(using: .png, properties: [:]) {
                    guard data.count <= 32_000_000 else { return }
                    var rect = CGRect(origin: .zero, size: image.size)
                    guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
                    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Kio/Clipboard/Images", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let imageURL = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
                    try data.write(to: imageURL, options: .atomic)
                    payload = .image(fileURL: imageURL, width: cgImage.width, height: cgImage.height)
                } else if let string = board.string(forType: .string), !string.isEmpty {
                    payload = .text(String(string.prefix(200_000)))
                } else { return }
                let fingerprint = ClipboardStore.fingerprint(for: payload)
                let retention = UserDefaults.standard.integer(forKey: "kio.clipboard.retentionDays")
                _ = try await clipboardStore.add(payload: payload, sourceBundleID: source, fingerprint: fingerprint,
                                                 retentionDays: retention == 0 ? 7 : retention)
                clipboardEntries = await clipboardStore.search()
            } catch { statusMessage = "Clipboard couldn't save that item locally." }
        }
    }

    private func startSessionInboxMonitor() {
        sessionTask?.cancel()
        sessionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.readSessionInbox()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func readSessionInbox() async {
        let inbox = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kio/Sessions/Inbox", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file), let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let providerValue = payload["provider"] as? String, let provider = SessionProvider(rawValue: providerValue) else { continue }
            let seconds = payload["timestamp"] as? Double ?? Date.now.timeIntervalSince1970
            guard let event = SessionHookAdapter.normalize(payload, provider: provider, now: Date(timeIntervalSince1970: seconds)) else { continue }
            do {
                guard try await sessionStore.ingest(event) else { continue }
                sessions = await sessionStore.snapshot()
                switch event.kind {
                case .needsInput: NotchEventCoordinator.shared.emit(.sessionNeedsInput, title: "\(provider.title) needs input")
                case .finished: NotchEventCoordinator.shared.emit(.sessionFinished, title: "\(provider.title) finished")
                case .failed: NotchEventCoordinator.shared.emit(.sessionFailed, title: "\(provider.title) failed")
                default: break
                }
            } catch { statusMessage = "Kio couldn't update the local Sessions list." }
        }
    }

    private func releaseSecurityScopes() {
        securityScopeURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        securityScopeURLs.removeAll()
    }
}
