import Foundation
import Testing
import KioCore
@testable import KioModel

@Test func dashboardSpacesAreTheFourPrimaryModules() {
    #expect(DashboardSpace.allCases == [.kio, .sessions, .clipboard, .news])
    #expect(DashboardSpace(rawValue: "news")?.title == "News")
}

@Test func ambientEventsSuppressDefaultNewsAndPrioritizeUrgentStates() {
    var queue = NotchEventQueue(maximumQueued: 4)
    let rejectedNews = queue.enqueue(NotchAmbientEvent(kind: .newsAlert, title: "Quiet headline"))
    #expect(!rejectedNews)
    #expect(queue.current == nil)
    let finished = queue.enqueue(NotchAmbientEvent(kind: .sessionFinished, title: "Codex finished"))
    let converted = queue.enqueue(NotchAmbientEvent(kind: .conversionComplete, title: "File ready"))
    let needsInput = queue.enqueue(NotchAmbientEvent(kind: .sessionNeedsInput, title: "Claude needs input"))
    #expect(finished && converted && needsInput)
    #expect(queue.current?.kind == .sessionNeedsInput)
    queue.dismissCurrent()
    let firstQueued = queue.current?.kind
    #expect(firstQueued == .sessionFinished)
    queue.dismissCurrent()
    #expect(queue.current?.kind == .conversionComplete)
    let explicitNews = queue.enqueue(NotchAmbientEvent(kind: .newsAlert, title: "Explicit alert"), allowNewsAlert: true)
    #expect(explicitNews)
}

@Test func sessionHooksNormalizeProviderLifecycleAndPermissionEvents() throws {
    let now = Date(timeIntervalSince1970: 100)
    let permission = try #require(SessionHookAdapter.normalize([
        "hook_event_name": "Notification", "notification_type": "permission_prompt",
        "session_id": "claude-1", "cwd": "/work/Kio", "prompt": "private prompt text"
    ], provider: .claude, now: now))
    #expect(permission.kind == .needsInput)
    #expect(permission.projectName == "Kio")
    #expect(!String(describing: permission).contains("private prompt text"))

    let failed = try #require(SessionHookAdapter.normalize([
        "event": "failed", "session_id": "cursor-1", "workspace_root": "/work/Website"
    ], provider: .cursor, now: now))
    #expect(failed.kind == .failed)
    #expect(failed.projectName == "Website")

    let started = try #require(SessionHookAdapter.normalize([
        "type": "started", "session_id": "opencode-1", "cwd": "/work/Notes"
    ], provider: .openCode, now: now))
    #expect(started.kind == .started)

    let openCodeCreated = try #require(SessionHookAdapter.normalize([
        "id": "event-4", "type": "session.created",
        "properties": ["info": ["id": "opencode-2", "directory": "/work/Notes"]]
    ], provider: .openCode, now: now))
    #expect(openCodeCreated.sessionID == "opencode-2")
    #expect(openCodeCreated.projectName == "Notes")

    let codexPermission = try #require(SessionHookAdapter.normalize([
        "hook_event_name": "PermissionRequest", "session_id": "thread-1", "cwd": "/work/Kio"
    ], provider: .codex, now: now))
    #expect(codexPermission.kind == .needsInput)
    let codexStop = try #require(SessionHookAdapter.normalize([
        "hook_event_name": "Stop", "session_id": "thread-1", "cwd": "/work/Kio"
    ], provider: .codex, now: now))
    #expect(codexStop.kind == .finished)
}

@Test func sessionStoreDeduplicatesAndKeepsRecentSessionsBounded() async throws {
    let location = FileManager.default.temporaryDirectory.appendingPathComponent("KioSessionTest-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: location) }
    let store = DeveloperSessionStore(fileURL: location, maximumSessions: 2)
    func event(_ id: Int, _ kind: SessionEventKind = .started) -> DeveloperSessionEvent {
        DeveloperSessionEvent(eventID: "event-\(id)", provider: .codex, sessionID: "session-\(id)", kind: kind,
                              projectName: "Project \(id)", occurredAt: Date(timeIntervalSince1970: Double(id)))
    }
    #expect(try await store.ingest(event(1)))
    #expect(!(try await store.ingest(event(1))))
    #expect(try await store.ingest(event(2)))
    #expect(try await store.ingest(event(3)))
    let sessions = await store.snapshot()
    #expect(sessions.count == 2)
    #expect(sessions.map(\.sessionID) == ["session-3", "session-2"])
}

@Test func sessionStateTransitionsKeepUnreadSignalsUntilTheUserReadsThem() {
    let started = DeveloperSessionEvent(eventID: "start", provider: .codex, sessionID: "thread-1",
        kind: .started, projectName: "Kio")
    var session = DeveloperSession(event: started)
    #expect(session.status == .running)
    #expect(!session.unreadEvent)

    session.apply(DeveloperSessionEvent(eventID: "permission", provider: .codex, sessionID: "thread-1",
        kind: .needsInput, projectName: "Kio", occurredAt: started.occurredAt.addingTimeInterval(1)))
    #expect(session.status == .needsInput)
    #expect(session.status.title == "Needs input")
    #expect(session.unreadEvent)

    session.unreadEvent = false
    session.apply(DeveloperSessionEvent(eventID: "stop", provider: .codex, sessionID: "thread-1",
        kind: .finished, projectName: "Kio", occurredAt: started.occurredAt.addingTimeInterval(2)))
    #expect(session.status == .finished)
    #expect(session.unreadEvent)

    session.apply(DeveloperSessionEvent(eventID: "idle", provider: .codex, sessionID: "thread-1",
        kind: .idle, projectName: "Kio", occurredAt: started.occurredAt.addingTimeInterval(3)))
    #expect(session.status == .idle)
    #expect(session.unreadEvent)
}

@Test func publicFeedURLPolicyRejectsPrivateAndUnsafeDestinationsWithoutNetworkAccess() throws {
    let publicURL = try PublicHTTPURLPolicy.publicHTTPURL("https://news.example/feed.xml", resolveDNS: false)
    #expect(publicURL.host == "news.example")

    for value in ["http://127.0.0.1/feed", "http://10.0.0.4/feed", "http://[::1]/feed", "file:///etc/passwd"] {
        #expect(throws: (any Error).self) {
            try PublicHTTPURLPolicy.publicHTTPURL(value, resolveDNS: false)
        }
    }
}

@Test func clipboardPolicySkipsConcealedTransientAndExcludedSources() {
    #expect(!ClipboardPrivacyPolicy.shouldCapture(types: ["public.utf8-plain-text", ClipboardPrivacyPolicy.concealedType], sourceBundleID: nil, excludedBundleIDs: []))
    #expect(!ClipboardPrivacyPolicy.shouldCapture(types: [ClipboardPrivacyPolicy.transientType], sourceBundleID: nil, excludedBundleIDs: []))
    #expect(!ClipboardPrivacyPolicy.shouldCapture(types: ["public.utf8-plain-text"], sourceBundleID: "password.manager", excludedBundleIDs: ["password.manager"]))
    #expect(ClipboardPrivacyPolicy.shouldCapture(types: ["public.utf8-plain-text"], sourceBundleID: "editor", excludedBundleIDs: []))
}

@Test func clipboardStoreDeduplicatesPinsAndAppliesRetentionAndEntryBound() async throws {
    let location = FileManager.default.temporaryDirectory.appendingPathComponent("KioClipboardTest-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: location) }
    let store = ClipboardStore(fileURL: location, maximumEntries: 2)
    let now = Date(timeIntervalSince1970: 1_000_000)
    func add(_ value: String, at capturedAt: Date = now) async throws {
        let payload = ClipboardPayload.text(value)
        _ = try await store.add(payload: payload, sourceBundleID: "editor",
                                fingerprint: ClipboardStore.fingerprint(for: payload),
                                now: capturedAt, retentionDays: 1)
    }
    try await add("keep")
    let first = try #require(await store.search().first)
    try await store.togglePin(first.id)
    #expect(try await store.add(payload: .text("keep"), sourceBundleID: "editor",
            fingerprint: ClipboardStore.fingerprint(for: .text("keep")), now: now, retentionDays: 1) == false)
    try await add("recent-a")
    try await add("recent-b")
    let entries = await store.search()
    #expect(entries.count == 3)
    #expect(entries.contains(where: { $0.id == first.id && $0.pinned }))
    try await add("fresh", at: now.addingTimeInterval(2 * 86_400))
    #expect(!(await store.search()).contains(where: { if case .text("recent-a") = $0.payload { true } else { false } }))
    #expect((await store.search()).contains(where: { $0.id == first.id }))
    #expect((await store.search()).contains(where: { if case .text("fresh") = $0.payload { true } else { false } }))
    try await store.clear()
    #expect(await store.search().isEmpty)
}

@Test func newsFeedParserSupportsRSSAndAtomAndKeepsPublisherTopic() throws {
    let source = NewsFeedSource(title: "Example Press", url: URL(string: "https://news.example/rss.xml")!, topic: "design")
    let rss = """
    <rss version="2.0"><channel><item><title>Ribbon layout update</title><link>https://news.example/story/1</link><pubDate>Fri, 02 Oct 2026 10:00:00 +0000</pubDate></item></channel></rss>
    """.data(using: .utf8)!
    let items = try NewsFeedParser.parse(rss, source: source)
    #expect(items.count == 1)
    #expect(items[0].publisher == "Example Press")
    #expect(items[0].topic == "design")
    #expect(items[0].url.absoluteString == "https://news.example/story/1")

    let atom = """
    <feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Atom story</title><link rel="alternate" href="https://news.example/story/2"/><updated>2026-10-02T10:00:00Z</updated></entry></feed>
    """.data(using: .utf8)!
    #expect(try NewsFeedParser.parse(atom, source: source).first?.headline == "Atom story")
}

@Test func newsStoreFiltersDeduplicatesBoundsAndOnlyAlertsConfiguredTopics() async throws {
    let location = FileManager.default.temporaryDirectory.appendingPathComponent("KioNewsTest-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: location) }
    let store = NewsStore(fileURL: location, maximumItems: 2)
    try await store.configure(sources: [], topics: ["design"], alertTopics: [])
    let ordinary = NewsItem(headline: "Quiet", publisher: "Paper", topic: "design", url: URL(string: "https://news.example/1")!)
    #expect(try await store.ingest([ordinary]).isEmpty)
    #expect(try await store.ingest([ordinary]).isEmpty)
    try await store.configure(sources: [], topics: ["design"], alertTopics: ["design"])
    let alert = NewsItem(headline: "Configured alert", publisher: "Paper", topic: "design", url: URL(string: "https://news.example/2")!)
    #expect(try await store.ingest([alert]).map(\.headline) == ["Configured alert"])
    let outOfTopic = NewsItem(headline: "Ignore", publisher: "Paper", topic: "finance", url: URL(string: "https://news.example/3")!)
    #expect(try await store.ingest([outOfTopic]).isEmpty)
    #expect((await store.items()).count == 2)
}

@Test func cueStableLayoutUsesFixedLinesAndMovesOnlyAfterCurrentLineAdvances() throws {
    let script = "one two three four five six\nnext paragraph"
    let alignment = CueTextAlignment(script: script)
    let layout = CueStableDocumentLayout.build(script: script, tokens: alignment.tokens, availableWidth: 35,
        measure: { _ in 10 })
    let sameLayoutAfterHighlightChange = CueStableDocumentLayout.build(script: script, tokens: alignment.tokens,
        availableWidth: 35, measure: { _ in 10 })
    #expect(layout == sameLayoutAfterHighlightChange)
    #expect(layout.tokenLineIndices.count == alignment.tokens.count)
    #expect(layout.scrollOffset(forToken: 0) == layout.scrollOffset(forToken: 1))
    #expect(layout.scrollOffset(forToken: 2) == layout.scrollOffset(forToken: 3))
    #expect(layout.scrollOffset(forToken: 4) > layout.scrollOffset(forToken: 2))
    #expect(layout.scrollOffset(forToken: alignment.tokens.count - 1) >= layout.scrollOffset(forToken: 4))
    #expect(CueStableDocumentLayout.fontSize == 17.5)

    let justifiedScript = "aa bb cc dd ee"
    let justifiedTokens = CueTextAlignment(script: justifiedScript).tokens
    let justified = CueStableDocumentLayout.build(script: justifiedScript, tokens: justifiedTokens, availableWidth: 50,
        measure: { _ in 8 })
    #expect(justified.lines.first?.isJustified == true)
    #expect(justified.lines.last?.isJustified == false)
    #expect(justified.lines.first?.interWordGap == 6)
}

@Test func convertParserMapsTypedLocalOperationsAndRejectsUnrelatedRequests() throws {
    let image = ArtifactRef(displayName: "photo.png", kind: .image, fileURL: URL(fileURLWithPath: "/tmp/photo.png"), sizeBytes: 1)
    let imageIntent = try #require(ConvertRequestParser.parse("jpeg under 2mb, 1200 px", inputs: [image]))
    #expect(imageIntent == .image(format: "jpeg", width: 1200, maximumBytes: 2_000_000))
    let video = ArtifactRef(displayName: "movie.mov", kind: .video, fileURL: URL(fileURLWithPath: "/tmp/movie.mov"), sizeBytes: 1)
    #expect(ConvertRequestParser.parse("mp3", inputs: [video]) == .extractAudio(format: .mp3))
    #expect(ConvertRequestParser.parse("make this cinematic", inputs: [video]) == .unsupported("That transformation isn't supported by Convert. Choose a format, resize width, or file-size target."))
}
