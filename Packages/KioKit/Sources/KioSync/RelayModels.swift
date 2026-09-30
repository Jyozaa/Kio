import Foundation

public struct RelayInvitationResponse: Decodable, Sendable {
    public let pairingID: String
    public let oneTimeToken: String
    public let workspaceID: String
    public let macDeviceID: String
    public let macPublicKey: String
    public let expiresAt: Int
}

public struct RelayDevice: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let role: String
    public let displayName: String
    public let publicKey: String
    public let lastSeen: Int
}

public struct RelayEnvelope: Decodable, Sendable {
    public let id: String
    public let senderID: String
    public let senderName: String
    public let senderPublicKey: String
    public let nonce: String
    public let ciphertext: String
    public let createdAt: String
}

public struct RelayPayload: Codable, Sendable {
    public let type: String
    public let text: String
    public let artifactName: String?
    public let artifactSize: Int?
    public let artifactMime: String?
    public let attachmentID: String?
    public let attachmentNonce: String?
    public let taskID: String?
    public let speaker: String?
    public let agent: String?
    public let createdAt: String

    public init(type: String, text: String, artifactName: String? = nil, artifactSize: Int? = nil, artifactMime: String? = nil, attachmentID: String? = nil, attachmentNonce: String? = nil, taskID: String? = nil, speaker: String? = nil, agent: String? = nil, createdAt: String = ISO8601DateFormatter().string(from: Date())) {
        self.type = type
        self.text = text
        self.artifactName = artifactName
        self.artifactSize = artifactSize
        self.artifactMime = artifactMime
        self.attachmentID = attachmentID
        self.attachmentNonce = attachmentNonce
        self.taskID = taskID
        self.speaker = speaker
        self.agent = agent
        self.createdAt = createdAt
    }
}

public struct RelayDevicesResponse: Decodable, Sendable { public let devices: [RelayDevice] }
public struct RelayInboxResponse: Decodable, Sendable { public let messages: [RelayEnvelope] }
public struct RelayErrorResponse: Decodable, Sendable { public let error: String }
