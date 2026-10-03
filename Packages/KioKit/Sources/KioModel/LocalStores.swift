import CryptoKit
import Foundation
import KioCore

public actor DeveloperSessionStore {
    private let fileURL: URL
    private var sessions: [DeveloperSession]
    private var recentEventIDs: [String]
    private let maximumSessions: Int
    public init(fileURL: URL? = nil, maximumSessions: Int = 80) {
        let resolvedURL = fileURL ?? DeveloperSessionStore.defaultURL
        self.fileURL = resolvedURL; self.maximumSessions = max(1, maximumSessions)
        if let data = try? Data(contentsOf: resolvedURL), let archive = try? JSONDecoder.kioLocal.decode(Archive.self, from: data) {
            sessions = archive.sessions; recentEventIDs = archive.eventIDs
        } else { sessions = []; recentEventIDs = [] }
    }
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kio/Sessions.json")
    }
    public func ingest(_ event: DeveloperSessionEvent) throws -> Bool {
        guard !recentEventIDs.contains(event.eventID) else { return false }
        recentEventIDs.append(event.eventID); recentEventIDs = Array(recentEventIDs.suffix(1_000))
        if let index = sessions.firstIndex(where: { $0.provider == event.provider && $0.sessionID == event.sessionID }) {
            sessions[index].apply(event)
        } else { sessions.append(DeveloperSession(event: event)) }
        sessions.sort { $0.lastActivityAt > $1.lastActivityAt }
        if sessions.count > maximumSessions {
            let active = sessions.filter { [.running, .needsInput].contains($0.status) }
            let inactive = sessions.filter { ![.running, .needsInput].contains($0.status) }
            let keptActive = Array(active.prefix(maximumSessions))
            sessions = keptActive + Array(inactive.prefix(max(0, maximumSessions - keptActive.count)))
        }
        try persist()
        return true
    }
    public func markRead(sessionID: String) throws {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].unreadEvent = false; try persist()
    }
    public func snapshot() -> [DeveloperSession] { sessions.sorted { $0.lastActivityAt > $1.lastActivityAt } }
    private struct Archive: Codable { let sessions: [DeveloperSession]; let eventIDs: [String] }
    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.kioLocal.encode(Archive(sessions: sessions, eventIDs: recentEventIDs))
        try data.write(to: fileURL, options: .atomic)
    }
}

public actor ClipboardStore {
    private let fileURL: URL
    private var entries: [ClipboardEntry]
    private var maximumEntries: Int
    private static let maximumImageStorageBytes = 128 * 1_000_000
    public init(fileURL: URL? = nil, maximumEntries: Int = 200) {
        let resolvedURL = fileURL ?? ClipboardStore.defaultURL
        self.fileURL = resolvedURL; self.maximumEntries = min(500, max(1, maximumEntries))
        if let data = try? Data(contentsOf: resolvedURL), let saved = try? JSONDecoder.kioLocal.decode([ClipboardEntry].self, from: data) {
            entries = Array(saved.sorted { $0.capturedAt > $1.capturedAt }.prefix(500))
        }
        else { entries = [] }
    }
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kio/Clipboard.json")
    }
    public func add(payload: ClipboardPayload, sourceBundleID: String?, fingerprint: String,
                    now: Date = .now, retentionDays: Int = 7) throws -> Bool {
        let previousImages = imageURLs(in: entries)
        prune(now: now, retentionDays: retentionDays)
        if let index = entries.firstIndex(where: { $0.fingerprint == fingerprint }) {
            entries[index].capturedAt = now
            let repeated = entries.remove(at: index); entries.insert(repeated, at: 0)
            let retained = imageURLs(in: entries)
            removeImagesNotIn(retained, previous: previousImages)
            removeNewImageIfNotRetained(payload, retained: retained)
            try persist(); return false
        }
        entries.insert(ClipboardEntry(payload: payload, capturedAt: now, sourceBundleID: sourceBundleID,
                                      fingerprint: fingerprint), at: 0)
        trimToBound()
        trimImageBudget()
        let retained = imageURLs(in: entries)
        removeImagesNotIn(retained, previous: previousImages)
        removeNewImageIfNotRetained(payload, retained: retained)
        try persist(); return true
    }
    public func togglePin(_ id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if !entries[index].pinned && entries.filter(\.pinned).count >= 500 {
            throw KioFailure.invalidInput("Kio can keep up to 500 pinned clipboard entries.")
        }
        entries[index].pinned.toggle(); try persist()
    }
    public func delete(_ id: UUID) throws {
        let previous = imageURLs(in: entries)
        entries.removeAll { $0.id == id }
        removeImagesNotIn(imageURLs(in: entries), previous: previous)
        try persist()
    }
    public func clear() throws {
        let previous = imageURLs(in: entries)
        entries.removeAll()
        removeImagesNotIn([], previous: previous)
        try persist()
    }
    public func search(_ query: String = "") -> [ClipboardEntry] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return entries }
        return entries.filter { entry in
            switch entry.payload {
            case .text(let text): text.localizedCaseInsensitiveContains(value)
            case .fileURLs(let urls): urls.contains { $0.lastPathComponent.localizedCaseInsensitiveContains(value) }
            case .image(let url, _, _): url.lastPathComponent.localizedCaseInsensitiveContains(value)
            }
        }
    }
    public func setMaximumEntries(_ value: Int) throws {
        let previous = imageURLs(in: entries)
        maximumEntries = min(500, max(1, value))
        trimToBound(maximumEntries)
        removeImagesNotIn(imageURLs(in: entries), previous: previous)
        try persist()
    }
    private func prune(now: Date, retentionDays: Int) {
        let threshold = now.addingTimeInterval(-Double(min(30, max(1, retentionDays))) * 86_400)
        entries.removeAll { !$0.pinned && $0.capturedAt < threshold }
    }
    private func trimToBound(_ maximum: Int? = nil) {
        let recentLimit = maximum ?? maximumEntries
        let pinned = entries.filter(\.pinned)
        let recentLimitAfterPins = min(recentLimit, max(0, 500 - pinned.count))
        let recent = Array(entries.filter { !$0.pinned }.prefix(recentLimitAfterPins))
        entries = (pinned + recent).sorted { $0.capturedAt > $1.capturedAt }
    }
    private func trimImageBudget() {
        var total = entries.reduce(Int64(0)) { sum, entry in
            guard case .image(let url, _, _) = entry.payload,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return sum }
            return sum + Int64(size)
        }
        guard total > Int64(Self.maximumImageStorageBytes) else { return }
        let oldestFirst = Array(entries.reversed())
        for entry in oldestFirst {
            guard case .image(let url, _, _) = entry.payload,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            entries.removeAll { $0.id == entry.id }
            total -= Int64(size)
            if isKioImageFile(url) { try? FileManager.default.removeItem(at: url) }
            if total <= Int64(Self.maximumImageStorageBytes) { break }
        }
    }
    private func imageURLs(in entries: [ClipboardEntry]) -> Set<URL> {
        Set(entries.compactMap { if case .image(let url, _, _) = $0.payload { url } else { nil } })
    }
    private func removeImagesNotIn(_ retained: Set<URL>, previous: Set<URL>) {
        for url in previous.subtracting(retained) where isKioImageFile(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }
    private func removeNewImageIfNotRetained(_ payload: ClipboardPayload, retained: Set<URL>) {
        guard case .image(let url, _, _) = payload, !retained.contains(url), isKioImageFile(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }
    private func isKioImageFile(_ url: URL) -> Bool {
        let root = fileURL.deletingLastPathComponent().appendingPathComponent("Clipboard/Images", isDirectory: true).standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(root + "/")
    }
    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.kioLocal.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }
    public static func fingerprint(for payload: ClipboardPayload) -> String {
        let raw: Data
        switch payload {
        case .text(let value): raw = Data("text:\(value)".utf8)
        case .fileURLs(let values): raw = Data(("files:" + values.map(\.standardizedFileURL.absoluteString).joined(separator: "\u{0}")).utf8)
        case .image(let url, let width, let height):
            var hasher = SHA256()
            hasher.update(data: Data("image:\(width)x\(height):".utf8))
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                while true {
                    guard let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
                    hasher.update(data: chunk)
                }
            } else { hasher.update(data: Data(url.standardizedFileURL.absoluteString.utf8)) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }
}

public actor NewsStore {
    private let fileURL: URL
    private var sources: [NewsFeedSource]
    private var topics: [String]
    private var alertTopics: Set<String>
    private var cache: [NewsItem]
    private let maximumItems: Int
    public init(fileURL: URL? = nil, maximumItems: Int = 160) {
        let resolvedURL = fileURL ?? NewsStore.defaultURL
        self.fileURL = resolvedURL; self.maximumItems = max(1, maximumItems)
        if let data = try? Data(contentsOf: resolvedURL), let saved = try? JSONDecoder.kioLocal.decode(Archive.self, from: data) {
            sources = saved.sources; topics = saved.topics; alertTopics = Set(saved.alertTopics); cache = saved.items
        } else { sources = []; topics = []; alertTopics = []; cache = [] }
    }
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kio/News.json")
    }
    public func configure(sources: [NewsFeedSource], topics: [String], alertTopics: Set<String>) throws {
        self.sources = Array(sources.prefix(30)); self.topics = Array(Set(topics.map(clean).filter { !$0.isEmpty }).prefix(30))
        self.alertTopics = Set(alertTopics.map(clean)); try persist()
    }
    public func configuredSources() -> [NewsFeedSource] { sources }
    public func configuredTopics() -> [String] { topics }
    public func configuration() -> NewsConfiguration { NewsConfiguration(sources: sources, topics: topics, alertTopics: alertTopics) }
    public func ingest(_ received: [NewsItem]) throws -> [NewsItem] {
        let allowed = Set(topics.map { $0.lowercased() })
        let filtered = received.filter { allowed.isEmpty || allowed.contains($0.topic.lowercased()) }
        let prior = Set(cache.map(\.id))
        cache = Array(Dictionary((cache + filtered).map { ($0.id, $0) }, uniquingKeysWith: { first, newest in
            (first.publishedAt ?? .distantPast) > (newest.publishedAt ?? .distantPast) ? first : newest
        }).values.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }.prefix(maximumItems))
        try persist()
        return filtered.filter { !prior.contains($0.id) && alertTopics.contains($0.topic.lowercased()) }
    }
    public func items() -> [NewsItem] { cache }
    public func refresh() async throws -> [NewsItem] {
        var all: [NewsItem] = []
        for source in sources {
            guard source.url.scheme?.lowercased() == "https", PublicHTTPURLPolicy.isHTTPURL(source.url) else {
                throw KioFailure.invalidInput("News sources must use a public HTTPS feed URL.")
            }
            try PublicHTTPURLPolicy.validatePublicHost(source.url.host ?? "")
            var request = URLRequest(url: source.url); request.timeoutInterval = 20
            request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
            let redirectPolicy = NewsFeedRedirectPolicy()
            let session = URLSession(configuration: .ephemeral, delegate: redirectPolicy, delegateQueue: nil)
            let (bytes, response) = try await session.bytes(for: request)
            defer { session.invalidateAndCancel() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
            guard let finalURL = response.url, finalURL.scheme?.lowercased() == "https",
                  PublicHTTPURLPolicy.isSafePublicHTTPURL(finalURL) else { continue }
            var data = Data()
            data.reserveCapacity(64 * 1_024)
            for try await byte in bytes {
                guard data.count < 2_000_000 else { throw KioFailure.invalidInput("A News feed exceeded Kio's 2 MB feed limit.") }
                data.append(byte)
            }
            all += (try? NewsFeedParser.parse(data, source: source)) ?? []
        }
        return try ingest(all)
    }
    private struct Archive: Codable { let sources: [NewsFeedSource]; let topics: [String]; let alertTopics: [String]; let items: [NewsItem] }
    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = Archive(sources: sources, topics: topics, alertTopics: Array(alertTopics), items: cache)
        try JSONEncoder.kioLocal.encode(archive).write(to: fileURL, options: .atomic)
    }
    private func clean(_ value: String) -> String { String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
}

private extension JSONDecoder {
    static var kioLocal: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
private extension JSONEncoder {
    static var kioLocal: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
}

private final class NewsFeedRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https",
              let host = url.host,
              (try? PublicHTTPURLPolicy.validatePublicHost(host)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
