import CryptoKit
import Foundation
import Security

public struct RelaySealedData: Sendable, Equatable {
    public let nonce: Data
    public let ciphertext: Data

    public init(nonce: Data, ciphertext: Data) {
        self.nonce = nonce
        self.ciphertext = ciphertext
    }
}

public enum RelayCryptography {
    private static let info = Data("Kio relay envelope v1".utf8)

    public static func seal(
        _ plaintext: Data,
        recipientPublicKey: Data,
        privateKey: P256.KeyAgreement.PrivateKey,
        workspaceID: String,
        nonce: Data? = nil
    ) throws -> RelaySealedData {
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: recipientPublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: recipient)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(workspaceID.utf8), sharedInfo: info, outputByteCount: 32)
        let nonceData = nonce ?? Self.randomNonce()
        guard nonceData.count == 12 else { throw RelayCryptoError.invalidNonce }
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonceData))
        return RelaySealedData(nonce: nonceData, ciphertext: box.ciphertext + box.tag)
    }

    public static func open(
        _ sealed: RelaySealedData,
        senderPublicKey: Data,
        privateKey: P256.KeyAgreement.PrivateKey,
        workspaceID: String
    ) throws -> Data {
        guard sealed.nonce.count == 12, sealed.ciphertext.count >= 16 else { throw RelayCryptoError.invalidEnvelope }
        let sender = try P256.KeyAgreement.PublicKey(x963Representation: senderPublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: sender)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(workspaceID.utf8), sharedInfo: info, outputByteCount: 32)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: sealed.nonce),
            ciphertext: sealed.ciphertext.dropLast(16),
            tag: sealed.ciphertext.suffix(16)
        )
        return try AES.GCM.open(box, using: key)
    }

    private static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}

private enum RelayCryptoError: Error {
    case invalidNonce
    case invalidEnvelope
}
