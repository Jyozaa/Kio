import Foundation
import KioCore

public enum DashboardSpace: String, Codable, CaseIterable, Identifiable, Sendable {
    case kio, sessions, clipboard, news
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self { case .kio: "sparkle"; case .sessions: "terminal"; case .clipboard: "doc.on.clipboard"; case .news: "newspaper" }
    }
}

public enum AmbientPriority: Int, Codable, Sendable, Comparable {
    case silent = 0, normal = 1, high = 2
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum NotchEventKind: String, Codable, Sendable {
    case sessionNeedsInput, sessionFinished, sessionFailed
    case conversionComplete, conversionFailed, reelComplete, reelFailed
    case newsAlert

    public var priority: AmbientPriority {
        switch self {
        case .sessionNeedsInput, .sessionFailed, .conversionFailed, .reelFailed: .high
        case .sessionFinished, .conversionComplete, .reelComplete, .newsAlert: .normal
        }
    }
    public var isVisibleByDefault: Bool { self != .newsAlert }
}

public struct NotchAmbientEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: NotchEventKind
    public let title: String
    public let createdAt: Date
    public init(id: UUID = UUID(), kind: NotchEventKind, title: String, createdAt: Date = .now) {
        self.id = id; self.kind = kind; self.title = String(title.prefix(96)); self.createdAt = createdAt
    }
}

/// Deterministic event arbitration shared by the dashboard and its ambient notch.
public struct NotchEventQueue: Sendable, Equatable {
    public private(set) var current: NotchAmbientEvent?
    public private(set) var queued: [NotchAmbientEvent] = []
    public let maximumQueued: Int
    public init(maximumQueued: Int = 8) { self.maximumQueued = max(0, maximumQueued) }

    public mutating func enqueue(_ event: NotchAmbientEvent, allowNewsAlert: Bool = false) -> Bool {
        guard event.kind.isVisibleByDefault || (event.kind == .newsAlert && allowNewsAlert) else { return false }
        guard let current else { self.current = event; return true }
        if event.kind.priority > current.kind.priority {
            insertByPriority(current, beforeEqualPriority: true)
            self.current = event
        } else if maximumQueued > 0 {
            insertByPriority(event)
        }
        return true
    }

    public mutating func dismissCurrent() {
        current = queued.isEmpty ? nil : queued.removeFirst()
    }

    private mutating func insertByPriority(_ event: NotchAmbientEvent, beforeEqualPriority: Bool = false) {
        guard maximumQueued > 0 else { return }
        let position = queued.firstIndex {
            $0.kind.priority < event.kind.priority || (beforeEqualPriority && $0.kind.priority == event.kind.priority)
        } ?? queued.endIndex
        queued.insert(event, at: position)
        if queued.count > maximumQueued { queued.removeLast() }
    }
}

public enum SessionProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, openCode, cursor
    public var id: String { rawValue }
    public var title: String {
        switch self { case .claude: "Claude Code"; case .codex: "Codex"; case .openCode: "OpenCode"; case .cursor: "Cursor" }
    }
}

public enum SessionStatus: String, Codable, Sendable {
    case running, needsInput, finished, failed, idle
    public var title: String {
        switch self {
        case .running: "Running"
        case .needsInput: "Needs input"
        case .finished: "Finished"
        case .failed: "Failed"
        case .idle: "Idle"
        }
    }
}
public enum SessionEventKind: String, Codable, Sendable { case started, activity, needsInput, finished, failed, idle, ended }

public struct DeveloperSessionEvent: Codable, Equatable, Sendable {
    public let eventID: String
    public let provider: SessionProvider
    public let sessionID: String
    public let kind: SessionEventKind
    public let projectName: String
    public let workingDirectory: String?
    public let occurredAt: Date
    public init(eventID: String, provider: SessionProvider, sessionID: String, kind: SessionEventKind,
                projectName: String, workingDirectory: String? = nil, occurredAt: Date = .now) {
        self.eventID = String(eventID.prefix(160)); self.provider = provider
        self.sessionID = String(sessionID.prefix(160)); self.kind = kind
        self.projectName = String(projectName.prefix(80)); self.workingDirectory = workingDirectory.map { String($0.prefix(1_024)) }
        self.occurredAt = occurredAt
    }
}

public struct DeveloperSession: Codable, Identifiable, Equatable, Sendable {
    public var id: String { "\(provider.rawValue):\(sessionID)" }
    public let provider: SessionProvider
    public let sessionID: String
    public var projectName: String
    public var workingDirectory: String?
    public var status: SessionStatus
    public let startedAt: Date
    public var lastActivityAt: Date
    public var unreadEvent: Bool
    public init(event: DeveloperSessionEvent) {
        provider = event.provider; sessionID = event.sessionID; projectName = event.projectName
        workingDirectory = event.workingDirectory; startedAt = event.occurredAt
        lastActivityAt = event.occurredAt; unreadEvent = false
        status = Self.status(for: event.kind)
    }
    public mutating func apply(_ event: DeveloperSessionEvent) {
        projectName = event.projectName.isEmpty ? projectName : event.projectName
        workingDirectory = event.workingDirectory ?? workingDirectory
        lastActivityAt = max(lastActivityAt, event.occurredAt)
        status = Self.status(for: event.kind)
        if [.needsInput, .finished, .failed].contains(event.kind) { unreadEvent = true }
    }
    private static func status(for kind: SessionEventKind) -> SessionStatus {
        switch kind {
        case .started, .activity: .running
        case .needsInput: .needsInput
        case .finished: .finished
        case .failed: .failed
        case .idle: .idle
        case .ended: .finished
        }
    }
}

/// Minimal hook payload. Provider adapters discard prompts, transcripts, and tool arguments.
public enum SessionHookAdapter {
    public static func normalize(_ payload: [String: Any], provider: SessionProvider, now: Date = .now) -> DeveloperSessionEvent? {
        let rawKind: String
        let sessionID: String
        let eventID: String
        let directory: String?
        let project: String
        switch provider {
        case .claude:
            rawKind = (payload["hook_event_name"] as? String ?? payload["event"] as? String ?? "").lowercased()
            sessionID = payload["session_id"] as? String ?? ""
            eventID = payload["event_id"] as? String ?? "\(sessionID):\(rawKind):\(Int(now.timeIntervalSince1970))"
            directory = payload["cwd"] as? String ?? payload["project_dir"] as? String
            project = Self.projectName(payload["project_name"] as? String, directory: directory)
        case .codex:
            rawKind = (payload["hook_event_name"] as? String ?? payload["type"] as? String
                ?? payload["event_type"] as? String ?? "").lowercased()
            sessionID = payload["thread_id"] as? String ?? payload["session_id"] as? String
                ?? payload["id"] as? String ?? ""
            eventID = payload["event_id"] as? String ?? "\(sessionID):\(rawKind):\(Int(now.timeIntervalSince1970))"
            directory = payload["cwd"] as? String ?? payload["working_directory"] as? String
            project = Self.projectName(payload["project_name"] as? String, directory: directory)
        case .cursor:
            rawKind = (payload["hook_event_name"] as? String ?? payload["event"] as? String ?? "").lowercased()
            sessionID = payload["session_id"] as? String ?? payload["conversation_id"] as? String ?? ""
            eventID = payload["generation_id"] as? String ?? "\(sessionID):\(rawKind):\(Int(now.timeIntervalSince1970))"
            directory = payload["workspace_root"] as? String ?? (payload["workspace_roots"] as? [String])?.first
            project = Self.projectName(payload["project_name"] as? String, directory: directory)
        case .openCode:
            rawKind = (payload["type"] as? String ?? payload["event"] as? String ?? "").lowercased()
            let properties = payload["properties"] as? [String: Any] ?? payload
            let info = properties["info"] as? [String: Any] ?? properties["session"] as? [String: Any] ?? [:]
            sessionID = properties["sessionID"] as? String ?? properties["session_id"] as? String
                ?? info["id"] as? String ?? info["sessionID"] as? String ?? ""
            eventID = payload["id"] as? String ?? "\(sessionID):\(rawKind):\(Int(now.timeIntervalSince1970))"
            directory = properties["directory"] as? String ?? properties["workingDirectory"] as? String
                ?? info["directory"] as? String ?? info["cwd"] as? String
            project = Self.projectName(properties["projectName"] as? String, directory: directory)
        }
        guard !sessionID.isEmpty, let kind = eventKind(rawKind, payload: payload) else { return nil }
        return DeveloperSessionEvent(eventID: eventID, provider: provider, sessionID: sessionID, kind: kind,
                                     projectName: project, workingDirectory: directory, occurredAt: now)
    }

    private static func eventKind(_ value: String, payload: [String: Any]) -> SessionEventKind? {
        if let normalized = SessionEventKind(rawValue: value), normalized != .ended { return normalized }
        if (payload["notification_type"] as? String)?.lowercased() == "permission_prompt" { return .needsInput }
        if value.contains("permission") || value.contains("action_required") || value.contains("needs_input") || value.contains("needsinput") { return .needsInput }
        if value.contains("error") || value.contains("failed") || value.contains("failure") { return .failed }
        if value.contains("stop") || value.contains("finished") || value.contains("turn_complete") || value.contains("idle") {
            return value.contains("idle") ? .idle : .finished
        }
        if value.contains("sessionstart") || value.contains("session.created") || value.contains("thread.started") { return .started }
        if value.contains("sessionend") || value.contains("session.deleted") || value == "ended" { return .ended }
        if value.contains("in_progress") || value.contains("running") || value.contains("activity") { return .activity }
        if value == "session.status", let status = (payload["status"] as? String)?.lowercased() {
            if status.contains("busy") || status.contains("running") { return .activity }
            if status.contains("idle") { return .idle }
        }
        return nil
    }

    private static func projectName(_ explicit: String?, directory: String?) -> String {
        if let explicit, !explicit.isEmpty { return String(explicit.prefix(80)) }
        guard let directory else { return "Project" }
        let name = URL(fileURLWithPath: directory).lastPathComponent
        return name.isEmpty ? "Project" : String(name.prefix(80))
    }
}

public enum ClipboardPayload: Codable, Equatable, Sendable {
    case text(String)
    case fileURLs([URL])
    case image(fileURL: URL, width: Int, height: Int)
}

public struct ClipboardEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var payload: ClipboardPayload
    public var capturedAt: Date
    public let sourceBundleID: String?
    public var pinned: Bool
    public let fingerprint: String
    public init(id: UUID = UUID(), payload: ClipboardPayload, capturedAt: Date = .now,
                sourceBundleID: String? = nil, pinned: Bool = false, fingerprint: String) {
        self.id = id; self.payload = payload; self.capturedAt = capturedAt
        self.sourceBundleID = sourceBundleID; self.pinned = pinned; self.fingerprint = fingerprint
    }
}

public enum ClipboardPrivacyPolicy {
    public static let concealedType = "org.nspasteboard.ConcealedType"
    public static let transientType = "org.nspasteboard.TransientType"
    public static func shouldCapture(types: [String], sourceBundleID: String?, excludedBundleIDs: Set<String>) -> Bool {
        guard !types.contains(concealedType), !types.contains(transientType) else { return false }
        if let sourceBundleID, excludedBundleIDs.contains(sourceBundleID) { return false }
        return !types.isEmpty
    }
}

public struct NewsItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String { url.absoluteString }
    public let headline: String
    public let publisher: String
    public let publishedAt: Date?
    public let topic: String
    public let url: URL
    public init(headline: String, publisher: String, publishedAt: Date? = nil, topic: String, url: URL) {
        self.headline = String(headline.prefix(400)); self.publisher = String(publisher.prefix(120))
        self.publishedAt = publishedAt; self.topic = String(topic.prefix(80)); self.url = url
    }
}

public struct NewsFeedSource: Codable, Identifiable, Equatable, Sendable {
    public var id: String { url.absoluteString }
    public let title: String
    public let url: URL
    public let topic: String
    public init(title: String, url: URL, topic: String) { self.title = title; self.url = url; self.topic = topic }
}

public struct NewsConfiguration: Codable, Equatable, Sendable {
    public let sources: [NewsFeedSource]
    public let topics: [String]
    public let alertTopics: Set<String>
    public init(sources: [NewsFeedSource], topics: [String], alertTopics: Set<String>) {
        self.sources = sources; self.topics = topics; self.alertTopics = alertTopics
    }
}

public enum NewsFeedParser {
    public static func parse(_ data: Data, source: NewsFeedSource) throws -> [NewsItem] {
        let parser = FeedXMLParser(publisher: source.title, topic: source.topic, feedURL: source.url)
        guard parser.parse(data) else { throw KioFailure.invalidInput("The RSS or Atom feed couldn't be read.") }
        return Array(parser.items.prefix(100))
    }
}

private final class FeedXMLParser: NSObject, XMLParserDelegate {
    private let publisher: String
    private let topic: String
    private let feedURL: URL
    private var currentElement = ""
    private var text = ""
    private var headline = ""
    private var link: URL?
    private var date: Date?
    private var inItem = false
    private let formatter = ISO8601DateFormatter()
    private(set) var items: [NewsItem] = []
    init(publisher: String, topic: String, feedURL: URL) { self.publisher = publisher; self.topic = topic; self.feedURL = feedURL }
    func parse(_ data: Data) -> Bool { let parser = XMLParser(data: data); parser.delegate = self; return parser.parse() }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName.lowercased(); text = ""
        if ["item", "entry"].contains(currentElement) { inItem = true; headline = ""; link = nil; date = nil }
        if currentElement == "link", let href = attributes["href"],
           attributes["rel"] == nil || attributes["rel"] == "alternate",
           let candidate = URL(string: href, relativeTo: feedURL)?.absoluteURL { link = candidate }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let element = elementName.lowercased(); let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            if element == "title" { headline = value }
            if element == "link", link == nil, let candidate = URL(string: value, relativeTo: feedURL)?.absoluteURL { link = candidate }
            if ["pubdate", "published", "updated", "dc:date"].contains(element) { date = formatter.date(from: value) ?? Self.rssDate(value) }
            if ["item", "entry"].contains(element) {
                if !headline.isEmpty, let link, ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
                    items.append(NewsItem(headline: headline, publisher: publisher, publishedAt: date, topic: topic, url: link))
                }
                inItem = false
            }
        }
        text = ""
    }
    private static func rssDate(_ value: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"; return formatter.date(from: value)
    }
}

public struct CueDocumentWord: Equatable, Sendable { public let index: Int; public let surface: String; public let width: Double }
public struct CueDocumentLine: Equatable, Sendable {
    public let words: [CueDocumentWord]
    public let paragraph: Int
    public let isJustified: Bool
    public let interWordGap: Double
}
public struct CueStableDocumentLayout: Equatable, Sendable {
    public let lines: [CueDocumentLine]
    public let tokenLineIndices: [Int]
    public let lineHeight: Double
    public static let fontSize = 17.5
    public static let lineSpacing = 6.0
    public static let paragraphSpacing = 13.0

    public static func build(script: String, availableWidth: Double, lineHeight: Double = 28,
                             measure: (String) -> Double) -> CueStableDocumentLayout {
        let paragraphs = script.components(separatedBy: .newlines)
        var allLines: [CueDocumentLine] = []
        var tokenLines: [Int] = []
        var globalIndex = 0
        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            let surfaces = paragraph.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !surfaces.isEmpty else { continue }
            var wrapped: [[CueDocumentWord]] = []
            var current: [CueDocumentWord] = []
            var currentWidth = 0.0
            for surface in surfaces {
                let width = max(0, measure(surface))
                let nextWidth = current.isEmpty ? width : currentWidth + Self.baseWordGap + width
                if !current.isEmpty && nextWidth > availableWidth {
                    wrapped.append(current); current = []; currentWidth = 0
                }
                let word = CueDocumentWord(index: globalIndex, surface: surface, width: width)
                current.append(word); currentWidth = current.count == 1 ? width : currentWidth + Self.baseWordGap + width
                globalIndex += 1
            }
            if !current.isEmpty { wrapped.append(current) }
            for (lineIndex, words) in wrapped.enumerated() {
                let measured = words.reduce(0) { $0 + $1.width }
                let isLast = lineIndex == wrapped.count - 1
                let gaps = max(1, words.count - 1)
                let justify = !isLast && words.count >= 3 && availableWidth > measured
                let gap = justify ? (availableWidth - measured) / Double(gaps) : Self.baseWordGap
                let lineIndex = allLines.count
                allLines.append(CueDocumentLine(words: words, paragraph: paragraphIndex,
                                                isJustified: justify, interWordGap: gap))
                tokenLines.append(contentsOf: words.map { _ in lineIndex })
            }
        }
        return CueStableDocumentLayout(lines: allLines, tokenLineIndices: tokenLines, lineHeight: lineHeight)
    }

    /// Builds lines from Cue's canonical tokens, preserving token indexes and paragraph breaks.
    public static func build(script: String, tokens: [CueToken], availableWidth: Double,
                             lineHeight: Double = 28, measure: (String) -> Double) -> CueStableDocumentLayout {
        guard !tokens.isEmpty else { return CueStableDocumentLayout(lines: [], tokenLineIndices: [], lineHeight: lineHeight) }
        let ns = script as NSString
        var grouped: [[(Int, String)]] = [[]]
        var paragraphIndex = 0
        var previousEnd = 0
        for (index, token) in tokens.enumerated() {
            let safeStart = min(max(previousEnd, 0), ns.length)
            let safeEnd = min(max(token.range.location, safeStart), ns.length)
            if safeEnd > safeStart {
                let between = ns.substring(with: NSRange(location: safeStart, length: safeEnd - safeStart))
                paragraphIndex += between.filter(\.isNewline).count
            }
            while grouped.count <= paragraphIndex { grouped.append([]) }
            grouped[paragraphIndex].append((index, token.surface))
            previousEnd = min(ns.length, NSMaxRange(token.range))
        }

        var allLines: [CueDocumentLine] = []
        var tokenLines = Array(repeating: 0, count: tokens.count)
        for (paragraph, entries) in grouped.enumerated() where !entries.isEmpty {
            var wrapped: [[CueDocumentWord]] = []
            var current: [CueDocumentWord] = []
            var currentWidth = 0.0
            for (index, surface) in entries {
                let width = max(0, measure(surface))
                let nextWidth = current.isEmpty ? width : currentWidth + Self.baseWordGap + width
                if !current.isEmpty && nextWidth > availableWidth {
                    wrapped.append(current); current = []; currentWidth = 0
                }
                current.append(CueDocumentWord(index: index, surface: surface, width: width))
                currentWidth = current.count == 1 ? width : currentWidth + Self.baseWordGap + width
            }
            if !current.isEmpty { wrapped.append(current) }
            for (lineInParagraph, words) in wrapped.enumerated() {
                let measured = words.reduce(0) { $0 + $1.width }
                let shouldJustify = lineInParagraph < wrapped.count - 1 && words.count >= 3 && availableWidth > measured
                let gap = shouldJustify ? (availableWidth - measured) / Double(words.count - 1) : Self.baseWordGap
                let lineIndex = allLines.count
                allLines.append(CueDocumentLine(words: words, paragraph: paragraph,
                                                isJustified: shouldJustify, interWordGap: gap))
                for word in words where tokenLines.indices.contains(word.index) { tokenLines[word.index] = lineIndex }
            }
        }
        return CueStableDocumentLayout(lines: allLines, tokenLineIndices: tokenLines, lineHeight: lineHeight)
    }
    private static let baseWordGap = 5.0
    public func line(forToken index: Int) -> Int { tokenLineIndices.indices.contains(index) ? tokenLineIndices[index] : 0 }
    public func scrollTargetLine(forToken index: Int) -> Int { max(0, line(forToken: index) - 1) }
    public func scrollOffset(forToken index: Int) -> Double { Double(scrollTargetLine(forToken: index)) * lineHeight }
}
