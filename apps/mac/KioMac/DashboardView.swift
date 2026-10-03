import AppKit
import KioCore
import KioModel
import KioTools
import SwiftUI
import UniformTypeIdentifiers

private enum KioFeature: String, CaseIterable { case convert = "Convert", reel = "Reel", cue = "Cue" }

struct KioSpaceView: View {
    @ObservedObject var model: KioDashboardModel
    let onAction: () -> Void
    @State private var feature: KioFeature = .convert
    @State private var showCue = false
    @State private var actionPulse = 0
    @FocusState private var commandFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    private var reduceMotion: Bool { accessibilityReduceMotion || UserDefaults.standard.bool(forKey: "kio.reduceMotion") }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                KioRibbon(action: actionPulse,
                          reduceMotion: reduceMotion)
                    .frame(width: 36, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kio").font(.system(size: 13, weight: .semibold))
                    Text(featureCaption).font(.system(size: 9)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer()
                ForEach(KioFeature.allCases, id: \.self) { option in
                    Button(option.rawValue) {
                        feature = option
                        if option == .cue { showCue = true; model.startCue() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: feature == option ? .semibold : .regular))
                    .foregroundStyle(feature == option ? .white : .white.opacity(0.5))
                }
            }
            if showCue {
                CueSurfaceView(onActiveChange: {
                    model.cueActiveChanged($0)
                    NotchPanelController.shared.cueSessionChanged($0)
                }, onDone: {
                    showCue = false
                    model.cueActiveChanged(false)
                    NotchPanelController.shared.cueSessionChanged(false)
                }, initialText: $model.cueInitialText)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !model.attachments.isEmpty { attachmentStrip }
                    if feature == .reel { reelPane }
                    else { commandField }
                    if model.isWorking { ProgressView().controlSize(.small).tint(.white.opacity(0.8)) }
                    if let status = model.statusMessage {
                        Text(status).font(.system(size: 9)).foregroundStyle(.white.opacity(0.62)).lineLimit(2)
                    }
                    if !model.outputs.isEmpty { outputStrip }
                    if model.attachments.isEmpty && !model.isWorking {
                        HStack(spacing: 8) {
                            suggestion("HEIC", command: "HEIC")
                            suggestion("JPEG < 2 MB", command: "JPEG under 2 MB")
                            suggestion("MP3", command: "MP3")
                            suggestion("PDF", command: "PDF")
                            Spacer(minLength: 0)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showCue)
        .onChange(of: model.attachments.first?.kind) { _, kind in
            guard let kind else { return }
            feature = kind == .url ? .reel : .convert
        }
        .onChange(of: model.isWorking) { _, working in
            if working { actionPulse &+= 1; onAction() }
        }
        .onChange(of: model.attachments.count) { _, count in if count > 0 { actionPulse &+= 1; onAction() } }
        .onChange(of: model.outputs.count) { _, count in if count > 0 { actionPulse &+= 1; onAction() } }
        .onChange(of: model.statusMessage) { _, message in
            if message?.localizedCaseInsensitiveContains("failed") == true { actionPulse &+= 1; onAction() }
        }
    }

    private var featureCaption: String {
        switch feature {
        case .convert: "Convert files · Reel media · Cue scripts"
        case .reel: "Paste a public media link"
        case .cue: "A calm teleprompter"
        }
    }

    private var commandField: some View {
        HStack(spacing: 8) {
            Image(systemName: model.attachments.isEmpty ? "arrow.down.doc" : "slider.horizontal.3")
                .foregroundStyle(.white.opacity(0.48))
            TextField(model.attachments.isEmpty ? "Drop files or paste a media link" : "JPEG under 2 MB, 1200 px, MP3…",
                      text: $model.commandText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($commandFocused)
                .onSubmit { submit() }
            Button { submit() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                    .foregroundStyle(.white.opacity(model.commandText.isEmpty && model.attachments.isEmpty ? 0.28 : 0.92))
            }
            .buttonStyle(.plain).disabled(model.isWorking)
        }
        .padding(.horizontal, 11).frame(height: 42)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.1), lineWidth: 1))
    }

    private var reelPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.attachments.first(where: { $0.kind == .url }) == nil {
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(.white.opacity(0.5))
                    TextField("Paste a public media link", text: $model.commandText).textFieldStyle(.plain)
                        .font(.system(size: 12)).onSubmit { submit() }
                    Button("Inspect") { submit() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                .padding(.horizontal, 10).frame(height: 38)
                .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 13))
            } else if let info = model.reelInfo {
                ReelDownloadCard(info: info, style: .expanded,
                    onDownloadVideo: { quality, format in Task { await model.downloadReelVideo(quality: quality, format: format) } },
                    onDownloadAudio: { format in Task { await model.downloadReelAudio(format: format) } },
                    onDownloadSubtitles: { Task { await model.downloadReelSubtitles() } })
            } else {
                Label(model.isInspectingReel ? "Inspecting link…" : "Media link ready", systemImage: "link")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var attachmentStrip: some View {
        HStack(spacing: 6) {
            ForEach(model.attachments) { item in
                HStack(spacing: 5) {
                    Image(systemName: icon(for: item.kind)).font(.system(size: 9))
                    Text(item.displayName).lineLimit(1).truncationMode(.middle).font(.system(size: 9))
                    Button { model.removeAttachment(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.white.opacity(0.08), in: Capsule())
            }
            Button("Clear") { model.clearAttachments() }.font(.system(size: 9)).buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 0)
        }
    }

    private var outputStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.outputs) { output in
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(red: 0.60, green: 0.79, blue: 0.98))
                    Text(output.displayName).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Open") { NSWorkspace.shared.open(output.fileURL) }.buttonStyle(.plain)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([output.fileURL]) } label: {
                        Image(systemName: "folder")
                    }.buttonStyle(.plain).help("Show in Finder")
                }
            }
        }
        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.8))
    }

    private func suggestion(_ title: String, command: String) -> some View {
        Button(title) {
            model.commandText = command
            if model.attachments.first?.kind == .url { feature = .reel }
            submit()
        }
        .buttonStyle(.plain).font(.system(size: 8, weight: .medium))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.white.opacity(0.07), in: Capsule())
        .foregroundStyle(.white.opacity(0.7))
    }

    private func submit() {
        let value = model.commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("https://") || value.hasPrefix("http://") {
            feature = .reel
            model.addMediaURL(value)
            model.commandText = ""
            return
        }
        if feature == .reel {
            model.addMediaURL(value)
            model.commandText = ""
            return
        }
        if model.attachments.first?.kind == .url {
            Task { await model.inspectReel() }
        } else {
            Task { await model.performConvert(value) }
        }
    }

    private func icon(for kind: ArtifactKind) -> String {
        switch kind { case .image: "photo"; case .video: "film"; case .audio: "waveform"; case .pdf: "doc.richtext"; case .url: "link"; default: "doc" }
    }
}

struct SessionsSpaceView: View {
    @ObservedObject var model: KioDashboardModel
    @State private var integrationMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Local lifecycle signals · no transcripts").font(.system(size: 8)).foregroundStyle(.white.opacity(0.42))
            }
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.sessions) { session in
                        HStack(spacing: 8) {
                            Circle().fill(statusColor(session.status)).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(session.provider.title).font(.system(size: 10, weight: .semibold))
                                    if session.unreadEvent { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.cyan) }
                                }
                                Text(session.projectName).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
                            }
                            Spacer()
                            Text(session.status.title).font(.system(size: 9)).foregroundStyle(statusColor(session.status))
                            Text(session.lastActivityAt, style: .relative).font(.system(size: 8)).foregroundStyle(.white.opacity(0.45))
                            if let directory = session.workingDirectory, !directory.isEmpty {
                                Button { reveal(session, directory: directory) } label: { Image(systemName: "arrow.up.forward.app") }
                                    .buttonStyle(.plain).help("Show project folder")
                            }
                        }
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { model.markSessionRead(session.id) }
                    }
                    if model.sessions.isEmpty {
                        Text("Enable a local hook below. Kio stores provider, project, status and times only.")
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.52)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(SessionProvider.allCases) { provider in
                    Button(SessionIntegrationManager.isInstalled(provider) ? "✓ \(provider.title)" : "+ \(provider.title)") {
                        do {
                            try SessionIntegrationManager.install(provider)
                            integrationMessage = "\(provider.title) hook enabled. Restart new sessions to send lifecycle events."
                        } catch { integrationMessage = error.localizedDescription }
                    }
                    .buttonStyle(.plain).font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                }
            }
            if let integrationMessage { Text(integrationMessage).font(.system(size: 8)).foregroundStyle(.white.opacity(0.55)).lineLimit(2) }
        }
    }

    private func statusColor(_ status: SessionStatus) -> Color {
        switch status { case .running: .green; case .needsInput: .orange; case .finished: .cyan; case .failed: .red; case .idle: .gray }
    }
    private func reveal(_ session: DeveloperSession, directory: String) {
        let url = URL(fileURLWithPath: directory)
        NSWorkspace.shared.open(url)
        model.markSessionRead(session.id)
    }
}

struct ClipboardSpaceView: View {
    @ObservedObject var model: KioDashboardModel
    @State private var query = ""
    private var filtered: [ClipboardEntry] {
        let values = model.clipboardEntries
        guard !query.isEmpty else { return values }
        return values.filter { entry in
            switch entry.payload {
            case .text(let text): text.localizedCaseInsensitiveContains(query)
            case .fileURLs(let urls): urls.contains { $0.lastPathComponent.localizedCaseInsensitiveContains(query) }
            case .image(let url, _, _): url.lastPathComponent.localizedCaseInsensitiveContains(query)
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Clipboard").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("Local history", isOn: Binding(get: { UserDefaults.standard.bool(forKey: "kio.clipboard.enabled") }, set: {
                    UserDefaults.standard.set($0, forKey: "kio.clipboard.enabled")
                })).toggleStyle(.switch).controlSize(.mini).font(.system(size: 8))
                Button("Clear") { model.clearClipboard() }.font(.system(size: 9)).buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.45))
                TextField("Search local items", text: $query).textFieldStyle(.plain).font(.system(size: 10))
            }
            .padding(7).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(filtered) { entry in
                        ClipboardRow(entry: entry, onCopy: { model.copyClipboardEntry(entry) },
                            onPin: { model.pinClipboard(entry.id) }, onDelete: { model.deleteClipboard(entry.id) })
                    }
                    if filtered.isEmpty { Text("Clipboard history is stored on this Mac only.").font(.system(size: 9)).foregroundStyle(.white.opacity(0.48)).padding(9) }
                }
            }
        }
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry
    let onCopy: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    private var title: String {
        switch entry.payload {
        case .text(let value):
            if let first = value.split(whereSeparator: \.isNewline).first { return String(first.prefix(90)) }
            return String(value.prefix(90))
        case .fileURLs(let urls): return urls.first?.lastPathComponent ?? "Files"
        case .image(_, let width, let height): return "Image · \(width) × \(height)"
        }
    }
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(.white.opacity(0.58))
            Button(action: onCopy) { Text(title).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain).font(.system(size: 9))
            Text(entry.capturedAt, style: .relative).font(.system(size: 8)).foregroundStyle(.white.opacity(0.4))
            Button(action: onPin) { Image(systemName: entry.pinned ? "pin.fill" : "pin") }
                .buttonStyle(.plain).help(entry.pinned ? "Unpin" : "Pin")
            Button(role: .destructive, action: onDelete) { Image(systemName: "xmark") }.buttonStyle(.plain)
                .help("Delete item")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.white.opacity(entry.pinned ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 8))
        .modifier(ClipboardDragModifier(url: dragURL))
    }
    private var symbol: String {
        switch entry.payload { case .text: "text.alignleft"; case .fileURLs: "doc"; case .image: "photo" }
    }
    private var dragURL: URL? {
        switch entry.payload { case .text: nil; case .fileURLs(let urls): urls.first; case .image(let url, _, _): url }
    }
}

private struct ClipboardDragModifier: ViewModifier {
    let url: URL?
    @ViewBuilder func body(content: Content) -> some View {
        if let url { content.onDrag { NSItemProvider(object: url as NSURL) } }
        else { content }
    }
}

struct NewsSpaceView: View {
    @ObservedObject var model: KioDashboardModel
    @State private var topicText = "technology, design"
    @State private var feedsText = ""
    @State private var alertTopicText = ""
    @State private var status: String?
    @AppStorage("kio.news.enabled") private var newsEnabled = true
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("News").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("Enabled", isOn: $newsEnabled).toggleStyle(.switch).controlSize(.mini).font(.system(size: 8))
                Button { Task { await model.refreshNews() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.system(size: 9))
                    .disabled(!newsEnabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.newsItems) { item in
                        Button { NSWorkspace.shared.open(item.url) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.headline).font(.system(size: 10, weight: .medium)).lineLimit(2)
                                Text([item.publisher, item.topic, item.publishedAt.map { $0.formatted(.relative(presentation: .named)) }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 8)).foregroundStyle(.white.opacity(0.48))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                    if model.newsItems.isEmpty { Text("Add public RSS or Atom feeds below. Headlines remain quiet unless you enable a topic alert.")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.52)).padding(8) }
                }
            }
            DisclosureGroup("Topics and feeds") {
                VStack(alignment: .leading, spacing: 5) {
                    TextField("Topics, comma separated", text: $topicText).textFieldStyle(.roundedBorder)
                    Text("One HTTPS feed per line: name | topic | feed URL")
                        .font(.system(size: 8)).foregroundStyle(.white.opacity(0.46))
                    TextEditor(text: $feedsText).font(.system(size: 9)).frame(height: 44)
                        .scrollContentBackground(.hidden).padding(4)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    TextField("Alert topics (optional), comma separated", text: $alertTopicText).textFieldStyle(.roundedBorder)
                    Button("Save feed settings") { save() }.buttonStyle(.borderedProminent).controlSize(.small)
                    if let status { Text(status).font(.system(size: 8)).foregroundStyle(.white.opacity(0.6)).lineLimit(2) }
                }.padding(.top, 5)
            }
            .font(.system(size: 9, weight: .medium))
        }
        .task { await loadExistingConfiguration() }
    }

    private func loadExistingConfiguration() async {
        let configuration = await model.newsConfiguration()
        if !configuration.topics.isEmpty { topicText = configuration.topics.joined(separator: ", ") }
        feedsText = configuration.sources.map { "\($0.title) | \($0.topic) | \($0.url.absoluteString)" }.joined(separator: "\n")
        alertTopicText = configuration.alertTopics.sorted().joined(separator: ", ")
    }
    private func save() {
        let topics = topicText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let sources: [NewsFeedSource] = feedsText.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3, let url = URL(string: parts[2]) else { return nil }
            return NewsFeedSource(title: parts[0], url: url, topic: parts[1])
        }
        let alerts = Set(alertTopicText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        Task {
            do { try await model.saveNewsPreferences(topics: topics, sources: sources, alertTopics: alerts); status = "Feed settings saved." }
            catch { status = error.localizedDescription }
        }
    }
}

struct ReelDownloadCard: View {
    enum Style { case compact, expanded }
    let info: ReelInspectionInfo
    let style: Style
    let onDownloadVideo: (String, String) -> Void
    let onDownloadAudio: (String) -> Void
    let onDownloadSubtitles: () -> Void
    @State private var quality = "best"
    @State private var videoFormat = "mp4"
    private let audioFormats = ["mp3", "m4a", "wav", "flac"]
    private var qualities: [String] { info.availableQualities }
    private var formats: [String] { info.availableVideoFormats(for: quality) }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                Text(info.source + duration).font(.system(size: 8)).foregroundStyle(.white.opacity(0.52))
            }
            HStack(spacing: 6) {
                Picker("Quality", selection: $quality) { ForEach(qualities, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 95)
                Picker("Format", selection: $videoFormat) { ForEach(formats, id: \.self) { Text($0.uppercased()).tag($0) } }
                    .labelsHidden().frame(width: 70)
                Button("Download") { onDownloadVideo(quality, videoFormat) }.buttonStyle(.borderedProminent).controlSize(.small)
                if info.audioAvailable == true {
                    Menu("Audio") { ForEach(audioFormats, id: \.self) { format in Button(format.uppercased()) { onDownloadAudio(format) } }
                    }.menuStyle(.borderlessButton)
                }
            }.font(.system(size: 9))
            HStack(spacing: 5) {
                Image(systemName: "waveform").foregroundStyle(.white.opacity(0.58))
                Text("Original audio preferred").foregroundStyle(.white.opacity(0.66))
                Spacer(minLength: 0)
                Button("Subtitles", action: onDownloadSubtitles).buttonStyle(.plain)
            }.font(.system(size: 8))
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: quality) { _, _ in if !formats.contains(videoFormat) { videoFormat = formats.first ?? "mp4" } }
        .task(id: info.remoteURL) {
            quality = qualities.contains("1080p") ? "1080p" : qualities.first ?? "best"
            videoFormat = formats.contains("mp4") ? "mp4" : formats.first ?? "mp4"
        }
    }
    private var duration: String {
        guard let seconds = info.durationSeconds, seconds.isFinite, seconds >= 0 else { return "" }
        return " · \(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))"
    }
}
