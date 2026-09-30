import AppKit
import KioCore
import KioUI
import SwiftUI
import UniformTypeIdentifiers

struct KioChatView: View {
    @ObservedObject private var workspace = KioWorkspace.shared
    @State private var message = ""
    @State private var isPickingFiles = false
    @State private var isDropTarget = false
    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.075))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(workspace.conversation) { item in
                            ConversationRow(item: item)
                                .id(item.id)
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
                    .padding(.horizontal, 30)
                    .padding(.vertical, 26)
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
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color(hex: AgentID.pixel.colorHex), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget, perform: acceptDrop)
        .fileImporter(isPresented: $isPickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { workspace.addURLs(urls) }
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
            HStack(spacing: 5) {
                ForEach([AgentID.pip, .pixel, .zip, .echo, .clerk], id: \.self) { agent in
                    AgentAvatar(agent, size: 23)
                        .help(agent.name)
                }
            }
            Button { isPickingFiles = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .frame(width: 32, height: 32)
                    .background(Color(hex: 0x1B1B1B), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Add files")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        workspace.submit(value)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let collector = ChatURLCollector()
        providers.forEach { provider in
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let url = item as? URL { collector.append(url) }
                else if let url = item as? NSURL { collector.append(url as URL) }
                else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { collector.append(url) }
            }
        }
        group.notify(queue: .main) { workspace.addURLs(collector.urls) }
        return true
    }
}

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
            }
            Spacer(minLength: 4)
            Button("Open") { NSWorkspace.shared.open(artifact.fileURL) }
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([artifact.fileURL]) }
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
