import Foundation
import Testing
import KioCore
@testable import KioModel

@Test func providerRequestsAndResponsesAreMockedForEveryCloudAdapter() async throws {
    let credentialStore = TestProviderCredentialStore()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProviderStubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = IntelligenceProviderClient(session: session, credentialStore: credentialStore)
    let key = "unit-test-secret-do-not-persist"

    let fixtures: [(IntelligenceProviderID, Data, String, String, String)] = [
        (.openAI, Data(#"{"choices":[{"message":{"content":"OpenAI reply"}}]}"#.utf8), "/v1/chat/completions", "Authorization", "OpenAI reply"),
        (.anthropic, Data(#"{"content":[{"type":"text","text":"Anthropic reply"}]}"#.utf8), "/v1/messages", "x-api-key", "Anthropic reply"),
        (.gemini, Data(#"{"candidates":[{"content":{"parts":[{"text":"Gemini reply"}]}}]}"#.utf8), "/v1beta/models/model-test:generateContent", "x-goog-api-key", "Gemini reply"),
        (.openRouter, Data(#"{"choices":[{"message":{"content":"OpenRouter reply"}}]}"#.utf8), "/api/v1/chat/completions", "Authorization", "OpenRouter reply"),
        (.groq, Data(#"{"choices":[{"message":{"content":"Groq reply"}}]}"#.utf8), "/openai/v1/chat/completions", "Authorization", "Groq reply")
    ]

    for (provider, response, path, keyHeader, expectedReply) in fixtures {
        ProviderStubURLProtocol.state.enqueue(status: 200, body: response)
        let reply = try await client.complete(provider: provider, model: "model-test", key: key,
                                              system: "Be concise", prompt: "Say hello", maxTokens: 32)
        #expect(reply == expectedReply)
        let request = try #require(ProviderStubURLProtocol.state.lastRequest)
        #expect(request.url?.path == path)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: keyHeader) == (keyHeader == "Authorization" ? "Bearer \(key)" : key))
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(ProviderStubURLProtocol.state.lastBody)
        #expect(String(decoding: body, as: UTF8.self).contains("Say hello"))
        #expect(!String(decoding: body, as: UTF8.self).contains(key))
    }
    #expect(ProviderStubURLProtocol.state.requests.count == fixtures.count)

    ProviderStubURLProtocol.state.enqueue(status: 429, body: Data(#"{"error":{"message":"quota exhausted"}}"#.utf8))
    do {
        _ = try await client.complete(provider: .openAI, model: "test", key: "dummy", system: "", prompt: "hello", maxTokens: 128)
        Issue.record("A provider error response must not be accepted.")
    } catch { #expect(error.localizedDescription.contains("quota exhausted")) }
    #expect(ProviderStubURLProtocol.state.requests.count == fixtures.count + 1)

    ProviderStubURLProtocol.state.enqueue(status: 200, body: Data(#"{"choices":[]}"#.utf8))
    do {
        _ = try await client.complete(provider: .groq, model: "test", key: "dummy", system: "", prompt: "hello", maxTokens: 128)
        Issue.record("A response without provider text must be rejected.")
    } catch { #expect(error.localizedDescription.contains("no text content")) }
    #expect(ProviderStubURLProtocol.state.requests.count == fixtures.count + 2)
}

@Test @MainActor func providerCredentialsUseInjectedStoreAndPreferencesNeverPersistTheKey() throws {
    let suite = "KioProviderAcceptance-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TestProviderCredentialStore()
    let settings = IntelligenceSettings(defaults: defaults, credentialStore: store)
    let secret = "dummy-test-key-only"

    settings.select(.openAI)
    try settings.saveKey("  \(secret)  ")
    #expect(settings.hasKey)
    #expect(store.read(service: IntelligenceProviderID.openAI.keychainService!) == secret)
    #expect(defaults.dictionaryRepresentation().values.compactMap { $0 as? String }.allSatisfy { !$0.contains(secret) })

    try settings.removeKey()
    #expect(!settings.hasKey)
    #expect(store.read(service: IntelligenceProviderID.openAI.keychainService!) == nil)
}

@Test func providerPrivacyAndMetadataPlanningRespectContentBoundary() throws {
    #expect(ContentPrivacyMode.metadataOnly.decisionForContentTransfer(needsContents: true) == .deny)
    #expect(ContentPrivacyMode.askBeforeContents.decisionForContentTransfer(needsContents: true) == .requiresConfirmation)
    #expect(ContentPrivacyMode.allowContents.decisionForContentTransfer(needsContents: true) == .allow)
    for mode in ContentPrivacyMode.allCases {
        #expect(mode.decisionForContentTransfer(needsContents: false) == .allow)
    }

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KioProviderMetadata-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("private-report.txt")
    try Data("PRIVATE_CONTENT_SENTINEL".utf8).write(to: file)
    let artifact = try ArtifactRef.inspect(file)
    let prompt = IntelligenceProviderClient.metadataPlanningPrompt(request: "Summarize the file", artifacts: [artifact])
    #expect(prompt.contains("private-report.txt [text, \(artifact.sizeBytes) bytes]"))
    #expect(!prompt.contains("PRIVATE_CONTENT_SENTINEL"))
    #expect(!prompt.contains(file.path))
}

private final class TestProviderCredentialStore: ProviderCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func read(service: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[service]
    }

    func save(_ value: String, service: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[service] = value
    }

    func remove(service: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: service)
    }
}

private final class ProviderStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = ProviderStubState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let fixture = Self.state.dequeue()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Self.state.record(request, body: Self.readBody(request.httpBodyStream))
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class ProviderStubState: @unchecked Sendable {
    private struct Fixture { let status: Int; let body: Data }
    private let lock = NSLock()
    private var fixtures: [Fixture] = []
    private var recordedRequests: [URLRequest] = []
    private var recordedBodies: [Data?] = []

    func enqueue(status: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        fixtures.append(Fixture(status: status, body: body))
    }

    func dequeue() -> (status: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !fixtures.isEmpty else { return (500, Data()) }
        let fixture = fixtures.removeFirst()
        return (fixture.status, fixture.body)
    }

    func record(_ request: URLRequest, body: Data?) {
        lock.lock(); defer { lock.unlock() }
        recordedRequests.append(request)
        recordedBodies.append(body)
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }

    var lastRequest: URLRequest? { requests.last }

    var lastBody: Data? {
        lock.lock(); defer { lock.unlock() }
        return recordedBodies.last ?? nil
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        fixtures.removeAll()
        recordedRequests.removeAll()
        recordedBodies.removeAll()
    }
}
