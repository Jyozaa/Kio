import Combine
import CryptoKit
import Foundation
import KioCore
import Security
import UniformTypeIdentifiers
import os

private struct RelayCredential: Codable, Sendable {
    let deviceID: String
    let authToken: String
    let privateKey: String
}

/// End-to-end encrypted device pairing and opaque envelope transport.
/// The relay sees device identifiers and ciphertext; it never receives file contents in plaintext.
@MainActor
public final class LocalRelayManager: ObservableObject {
    public static let shared = LocalRelayManager()

    @Published public private(set) var isConfigured = false
    @Published public private(set) var isOnline = false
    @Published public private(set) var isPairing = false
    @Published public private(set) var pairingURL: URL?
    @Published public private(set) var pairingExpiresAt: Date?
    @Published public private(set) var devices: [RelayDevice] = []
    @Published public private(set) var statusMessage = "Relay not configured"
    @Published public private(set) var lastError: String?

    public var onIncomingRequest: (@MainActor (String, RelayPayload, [Data]?) -> Void)?

    private let logger = Logger(subsystem: "app.kio.mac", category: "Relay")
    private let session: URLSession
    private let keychain = RelayKeychain()
    private var credential: RelayCredential?
    private var privateKey: P256.KeyAgreement.PrivateKey?
    private var publicKey: P256.KeyAgreement.PublicKey?
    private var baseURL: URL?
    private var pollTask: Task<Void, Never>?
    private var credentialRestoreTask: Task<Void, Never>?
    private var knownDevices: [String: RelayDevice] = [:]

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 28
        configuration.timeoutIntervalForResource = 32
        session = URLSession(configuration: configuration)
        if let configured = UserDefaults.standard.string(forKey: "kio.relayURL"), let valid = Self.validBaseURL(configured) {
            baseURL = valid
            isConfigured = true
            statusMessage = "Pair a phone to activate the relay"
        }
    }

    public func activate() { startPollingIfPaired() }

    public func configure(relayURL raw: String) {
        guard let url = Self.validBaseURL(raw) else {
            pollTask?.cancel()
            pollTask = nil
            credentialRestoreTask?.cancel()
            credentialRestoreTask = nil
            baseURL = nil
            isConfigured = false
            isOnline = false
            statusMessage = "Enter the deployed Kio relay URL"
            return
        }

        // A Keychain read may be waiting on macOS authorization even if its
        // awaiting task was cancelled. Reusing an in-flight check prevents
        // repeated Connect clicks from stacking Security.framework prompts.
        if baseURL == url, pollTask != nil || credentialRestoreTask != nil {
            isConfigured = true
            UserDefaults.standard.set(url.absoluteString, forKey: "kio.relayURL")
            return
        }

        pollTask?.cancel()
        pollTask = nil
        credentialRestoreTask?.cancel()
        credentialRestoreTask = nil
        pairingURL = nil
        devices = []
        knownDevices = [:]
        baseURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: "kio.relayURL")
        isConfigured = true
        statusMessage = "Connecting securely…"
        lastError = nil
        startPollingIfPaired()
    }

    public func createPairing() async {
        guard let baseURL else { return }
        isPairing = true
        lastError = nil
        defer { isPairing = false }
        do {
            try loadOrCreateCredential()
            guard let credential, let publicKey else { throw RelayError.identityUnavailable }
            var request = URLRequest(url: apiURL("pairings", baseURL: baseURL))
            request.httpMethod = "POST"
            request.setValue("Bearer \(credential.authToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "deviceID": credential.deviceID,
                "deviceName": Host.current().localizedName ?? "Kio Mac",
                "publicKey": Self.encode(publicKey.x963Representation)
            ])
            let (data, response) = try await session.data(for: request)
            try Self.check(response, data: data)
            let invitation = try JSONDecoder().decode(RelayInvitationResponse.self, from: data)
            let qr = PairingQR(version: 1, relayURL: baseURL.absoluteString, workspaceID: invitation.workspaceID, macDeviceID: invitation.macDeviceID, pairingID: invitation.pairingID, oneTimeToken: invitation.oneTimeToken, macPublicKey: invitation.macPublicKey)
            let encoded = try JSONEncoder().encode(qr)
            pairingURL = URL(string: "\(baseURL.absoluteString)#pair=\(Self.encodeURLToken(encoded))")
            pairingExpiresAt = Date(timeIntervalSince1970: TimeInterval(invitation.expiresAt))
            statusMessage = "Scan this one-time code with your phone"
            startPollingIfPaired()
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Could not create pairing code"
        }
    }

    public func revokePhone(_ deviceID: String) async {
        guard let baseURL, let credential else { return }
        do {
            var request = URLRequest(url: apiURL("devices/\(deviceID)", baseURL: baseURL))
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(credential.authToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            try Self.check(response, data: data)
            devices.removeAll { $0.id == deviceID }
            knownDevices.removeValue(forKey: deviceID)
        } catch { lastError = error.localizedDescription }
    }

    public func sendReply(type: String, text: String, taskID: String?, artifactURL: URL?, artifactURLs: [URL]? = nil,
                          to deviceID: String, speaker: String? = nil, agent: String? = nil) async {
        guard let baseURL, let credential, let privateKey else { return }
        do {
            var manifest: [RelayAttachment] = []
            var legacyName: String?
            var legacySize: Int?
            var legacyMime: String?
            var legacyID: String?
            var legacyNonce: String?
            var transferNote: String?
            let devices = try await fetchDevices(baseURL: baseURL, credential: credential)
            guard let recipient = devices.first(where: { $0.id == deviceID && $0.role == "phone" }) else { throw RelayError.deviceUnavailable }
            let urls = Array((artifactURLs ?? artifactURL.map { [$0] } ?? []).prefix(8))
            var uploadedBytes = 0
            var skipped = 0
            for url in urls {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size > 0, size <= 50 * 1_024 * 1_024,
                      uploadedBytes + size <= 150 * 1_024 * 1_024 else { skipped += 1; continue }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let transfer = try await uploadEncryptedFile(data, recipientID: deviceID, recipientPublicKey: recipient.publicKey, baseURL: baseURL, credential: credential, privateKey: privateKey)
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                manifest.append(RelayAttachment(transferID: transfer.id, nonce: transfer.nonce, name: url.lastPathComponent, size: size, mime: mime))
                uploadedBytes += size
            }
            if urls.count > 8 { skipped += urls.count - 8 }
            if skipped > 0 {
                transferNote = " \(skipped) result file\(skipped == 1 ? " was" : "s were") too large or beyond the phone transfer limit, and remain available on this Mac."
                lastError = "Some result files exceeded the phone transfer limit."
            }
            if manifest.count == 1, let first = manifest.first {
                legacyName = first.name
                legacySize = first.size
                legacyMime = first.mime
                legacyID = first.transferID
                legacyNonce = first.nonce
            }
            let payload = RelayPayload(type: type, text: text + (transferNote ?? ""), artifactName: legacyName,
                                        artifactSize: legacySize, artifactMime: legacyMime, attachmentID: legacyID,
                                        attachmentNonce: legacyNonce, attachments: manifest.isEmpty ? nil : manifest,
                                        taskID: taskID, speaker: speaker, agent: agent)
            let sealed = try Self.seal(payload, recipientPublicKey: recipient.publicKey, privateKey: privateKey, workspaceID: credential.deviceID)
            try await postEnvelope(sealed, recipientID: deviceID, baseURL: baseURL, credential: credential)
        } catch {
            lastError = error.localizedDescription
            logger.error("Could not send encrypted relay response: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startPollingIfPaired() {
        guard pollTask == nil, credentialRestoreTask == nil, let baseURL else { return }
        isOnline = false
        statusMessage = "Checking saved phone pairing…"
        lastError = nil
        let keychain = self.keychain
        credentialRestoreTask = Task { [weak self] in
            await self?.restoreCredentialAndStartPolling(baseURL: baseURL, keychain: keychain)
        }
    }

    private func restoreCredentialAndStartPolling(baseURL: URL, keychain: RelayKeychain) async {
        defer { credentialRestoreTask = nil }
        do {
            // SecItemCopyMatching can wait for a macOS Keychain authorization
            // sheet. Keep that wait off the main actor so Kio remains responsive.
            let saved = try await Task.detached(priority: .userInitiated) {
                try keychain.read()
            }.value
            guard !Task.isCancelled, self.baseURL == baseURL else { return }
            guard let saved else {
                isOnline = false
                statusMessage = "Pair a phone to activate the relay"
                logger.notice("No saved relay pairing identity was found for the configured URL")
                return
            }
            try applyCredential(saved)
            logger.info("Loaded the saved relay identity and started connection attempts")
            pollTask = Task { [weak self] in await self?.pollLoop(baseURL: baseURL, credential: saved) }
        } catch {
            guard !Task.isCancelled, self.baseURL == baseURL else { return }
            lastError = error.localizedDescription
            statusMessage = "Could not access the saved phone pairing"
            logger.error("Could not load the saved relay identity: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pollLoop(baseURL: URL, credential: RelayCredential) async {
        guard let privateKey else {
            lastError = RelayError.identityUnavailable.localizedDescription
            isOnline = false
            return
        }
        var delay: UInt64 = 1
        while !Task.isCancelled {
            do {
                let devices = try await fetchDevices(baseURL: baseURL, credential: credential)
                self.devices = devices.filter { $0.role == "phone" }
                knownDevices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
                var request = URLRequest(url: apiURL("inbox?wait=18", baseURL: baseURL))
                request.setValue("Bearer \(credential.authToken)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await session.data(for: request)
                try Self.check(response, data: data)
                let inbox = try JSONDecoder().decode(RelayInboxResponse.self, from: data)
                isOnline = true
                statusMessage = "Mac online · \(self.devices.count) paired phone\(self.devices.count == 1 ? "" : "s")"
                lastError = nil
                delay = 1
                for envelope in inbox.messages {
                    guard envelope.senderPublicKey == knownDevices[envelope.senderID]?.publicKey,
                          let payload = try? Self.open(envelope, privateKey: privateKey, workspaceID: credential.deviceID),
                          payload.type == "request" else {
                        await acknowledge(envelope.id, baseURL: baseURL, credential: credential)
                        continue
                    }
                    var attachmentData: [Data] = []
                    var attachmentTransferIDs: [String] = []
                    let manifest: [RelayAttachment]
                    if let attachments = payload.attachments {
                        guard (1...8).contains(attachments.count), attachments.allSatisfy({ (1...50 * 1_024 * 1_024).contains($0.size) }),
                              attachments.reduce(0, { $0 + $1.size }) <= 150 * 1_024 * 1_024 else {
                            lastError = "This phone request has too many attachments or exceeds Kio's transfer limit."
                            await acknowledge(envelope.id, baseURL: baseURL, credential: credential)
                            continue
                        }
                        manifest = attachments
                    } else if payload.attachmentID != nil || payload.attachmentNonce != nil {
                        guard let transferID = payload.attachmentID, let nonce = payload.attachmentNonce,
                              let name = payload.artifactName, let size = payload.artifactSize, size > 0, size <= 50 * 1_024 * 1_024 else {
                            lastError = "A phone request had incomplete attachment details and was discarded."
                            await acknowledge(envelope.id, baseURL: baseURL, credential: credential)
                            continue
                        }
                        manifest = [RelayAttachment(transferID: transferID, nonce: nonce, name: name, size: size, mime: payload.artifactMime ?? "application/octet-stream")]
                    } else { manifest = [] }

                    do {
                        for attachment in manifest {
                            let data = try await downloadEncryptedFile(attachment.transferID, nonce: attachment.nonce, senderPublicKey: envelope.senderPublicKey, declaredSize: attachment.size, baseURL: baseURL, credential: credential, privateKey: privateKey)
                            attachmentData.append(data)
                            attachmentTransferIDs.append(attachment.transferID)
                        }
                    } catch {
                        logger.error("Phone file transfer failed verification: \(error.localizedDescription, privacy: .public)")
                        lastError = "A phone attachment could not be verified; the request was discarded."
                        await acknowledge(envelope.id, baseURL: baseURL, credential: credential)
                        continue
                    }
                    onIncomingRequest?(envelope.senderID, payload, attachmentData.isEmpty ? nil : attachmentData)
                    for attachmentTransferID in attachmentTransferIDs { await acknowledgeFile(attachmentTransferID, baseURL: baseURL, credential: credential) }
                    await acknowledge(envelope.id, baseURL: baseURL, credential: credential)
                }
            } catch is CancellationError { break }
            catch {
                isOnline = false
                statusMessage = "Mac offline · reconnecting"
                logger.error("Relay connection interrupted: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
        isOnline = false
    }

    private func fetchDevices(baseURL: URL, credential: RelayCredential) async throws -> [RelayDevice] {
        var request = URLRequest(url: apiURL("devices", baseURL: baseURL))
        request.setValue("Bearer \(credential.authToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        return try JSONDecoder().decode(RelayDevicesResponse.self, from: data).devices
    }

    private func postEnvelope(_ encrypted: EncryptedPayload, recipientID: String, baseURL: URL, credential: RelayCredential) async throws {
        var request = URLRequest(url: apiURL("messages", baseURL: baseURL))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["recipientID": recipientID, "nonce": encrypted.nonce, "ciphertext": encrypted.ciphertext])
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
    }

    private func acknowledge(_ messageID: String, baseURL: URL, credential: RelayCredential) async {
        var request = URLRequest(url: apiURL("messages/\(messageID)/ack", baseURL: baseURL))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.authToken)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    private func acknowledgeFile(_ transferID: String, baseURL: URL, credential: RelayCredential) async {
        var request = URLRequest(url: apiURL("files/\(transferID)/ack", baseURL: baseURL))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.authToken)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    private func uploadEncryptedFile(_ data: Data, recipientID: String, recipientPublicKey: String, baseURL: URL, credential: RelayCredential, privateKey: P256.KeyAgreement.PrivateKey) async throws -> UploadedTransfer {
        let sealed = try RelayCryptography.seal(data, recipientPublicKey: Self.decode(recipientPublicKey), privateKey: privateKey, workspaceID: credential.deviceID)
        var request = URLRequest(url: apiURL("files?recipientID=\(recipientID)", baseURL: baseURL))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "X-Kio-File-Size")
        request.httpBody = sealed.ciphertext
        let (responseData, response) = try await session.data(for: request)
        try Self.check(response, data: responseData)
        let result = try JSONDecoder().decode(RelayTransferResponse.self, from: responseData)
        return UploadedTransfer(id: result.id, nonce: Self.encode(sealed.nonce))
    }

    private func downloadEncryptedFile(_ transferID: String, nonce: String, senderPublicKey: String, declaredSize: Int?, baseURL: URL, credential: RelayCredential, privateKey: P256.KeyAgreement.PrivateKey) async throws -> Data {
        var request = URLRequest(url: apiURL("files/\(transferID)", baseURL: baseURL))
        request.setValue("Bearer \(credential.authToken)", forHTTPHeaderField: "Authorization")
        let (encrypted, response) = try await session.data(for: request)
        try Self.check(response, data: encrypted)
        guard encrypted.count <= 50 * 1024 * 1024 + 16 else { throw RelayError.transferLimit }
        let sealed = RelaySealedData(nonce: Self.decode(nonce), ciphertext: encrypted)
        let clear = try RelayCryptography.open(sealed, senderPublicKey: Self.decode(senderPublicKey), privateKey: privateKey, workspaceID: credential.deviceID)
        guard clear.count <= 50 * 1024 * 1024, declaredSize == clear.count else { throw RelayError.transferVerification }
        return clear
    }

    private func loadOrCreateCredential() throws {
        if try keychain.read() != nil { try loadCredentialIfPresent(); return }
        let key = P256.KeyAgreement.PrivateKey()
        let credential = RelayCredential(deviceID: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), authToken: Self.randomToken(), privateKey: Self.encode(key.rawRepresentation))
        try keychain.save(credential)
        self.credential = credential
        privateKey = key
        publicKey = key.publicKey
    }

    private func loadCredentialIfPresent() throws {
        guard let saved = try keychain.read() else { return }
        try applyCredential(saved)
    }

    private func applyCredential(_ credential: RelayCredential) throws {
        let keyData = Self.decode(credential.privateKey)
        let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: keyData)
        self.credential = credential
        privateKey = key
        publicKey = key.publicKey
    }

    private func apiURL(_ path: String, baseURL: URL) -> URL {
        URL(string: "/api/\(path)", relativeTo: baseURL)!.absoluteURL
    }

    private static func validBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme, let host = components.host,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              (scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1"].contains(host))) else { return nil }
        return URL(string: "\(scheme)://\(host)\(components.port.map { ":\($0)" } ?? "")")
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(RelayErrorResponse.self, from: data).error) ?? "Relay request failed. Check the URL and try again."
            throw RelayError.server(message)
        }
    }

    private static func seal(_ payload: RelayPayload, recipientPublicKey: String, privateKey: P256.KeyAgreement.PrivateKey, workspaceID: String) throws -> EncryptedPayload {
        let sealed = try RelayCryptography.seal(JSONEncoder().encode(payload), recipientPublicKey: decode(recipientPublicKey), privateKey: privateKey, workspaceID: workspaceID)
        return EncryptedPayload(nonce: encode(sealed.nonce), ciphertext: encode(sealed.ciphertext))
    }

    private static func open(_ envelope: RelayEnvelope, privateKey: P256.KeyAgreement.PrivateKey?, workspaceID: String) throws -> RelayPayload {
        guard let privateKey else { throw RelayError.identityUnavailable }
        let sealed = RelaySealedData(nonce: decode(envelope.nonce), ciphertext: decode(envelope.ciphertext))
        let clear = try RelayCryptography.open(sealed, senderPublicKey: decode(envelope.senderPublicKey), privateKey: privateKey, workspaceID: workspaceID)
        return try JSONDecoder().decode(RelayPayload.self, from: clear)
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return encode(Data(bytes))
    }

    private static func encode(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private static func encodeURLToken(_ data: Data) -> String { encode(data) }
    private static func decode(_ value: String) -> Data {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized) ?? Data()
    }
}

private struct PairingQR: Encodable {
    let version: Int
    let relayURL: String
    let workspaceID: String
    let macDeviceID: String
    let pairingID: String
    let oneTimeToken: String
    let macPublicKey: String
}

private struct EncryptedPayload { let nonce: String; let ciphertext: String }
private struct RelayTransferResponse: Decodable { let id: String }
private struct UploadedTransfer { let id: String; let nonce: String }

private enum RelayError: LocalizedError {
    case identityUnavailable
    case deviceUnavailable
    case encryption
    case transferLimit
    case transferVerification
    case server(String)

    var errorDescription: String? {
        switch self {
        case .identityUnavailable: "Kio couldn't access its protected pairing identity."
        case .deviceUnavailable: "The paired phone isn't available. Create a fresh pairing code."
        case .encryption: "Kio couldn't encrypt that message."
        case .transferLimit: "That encrypted file exceeds the 50 MB transfer limit."
        case .transferVerification: "Kio could not verify the downloaded file."
        case .server(let message): message
        }
    }
}

private struct RelayKeychain: Sendable {
    private let service = "app.kio.mac.relay"
    private let account = "device-identity-v1"

    func read() throws -> RelayCredential? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw RelayError.identityUnavailable }
        return try JSONDecoder().decode(RelayCredential.self, from: data)
    }

    func save(_ credential: RelayCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            values.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw RelayError.identityUnavailable }
        } else if status != errSecSuccess { throw RelayError.identityUnavailable }
    }
}
