import CryptoKit
import Foundation
import Testing
@testable import KioSync

@Test func phoneAndMacDeriveTheSameAuthenticatedKey() throws {
    let fixtureURL = try #require(Bundle.module.url(forResource: "relay-crypto-vector", withExtension: "json"))
    let fixture = try JSONDecoder().decode(CryptoFixture.self, from: Data(contentsOf: fixtureURL))
    let macPrivate = try P256.KeyAgreement.PrivateKey(rawRepresentation: decode(fixture.macPrivateKey))
    let phonePrivate = try P256.KeyAgreement.PrivateKey(rawRepresentation: decode(fixture.phonePrivateKey))
    let payload = Data(fixture.plaintext.utf8)
    let nonce = decode(fixture.nonce)

    let fromPhone = try RelayCryptography.seal(payload, recipientPublicKey: macPrivate.publicKey.x963Representation, privateKey: phonePrivate, workspaceID: fixture.workspaceID, nonce: nonce)
    #expect(encode(fromPhone.ciphertext) == fixture.ciphertext)
    #expect(encode(macPrivate.publicKey.x963Representation) == fixture.macPublicKey)
    #expect(encode(phonePrivate.publicKey.x963Representation) == fixture.phonePublicKey)
    let openedByMac = try RelayCryptography.open(fromPhone, senderPublicKey: phonePrivate.publicKey.x963Representation, privateKey: macPrivate, workspaceID: fixture.workspaceID)
    #expect(openedByMac == payload)

    let fromMac = try RelayCryptography.seal(payload, recipientPublicKey: phonePrivate.publicKey.x963Representation, privateKey: macPrivate, workspaceID: fixture.workspaceID, nonce: nonce)
    #expect(fromMac.ciphertext == fromPhone.ciphertext)
    let openedByPhone = try RelayCryptography.open(fromMac, senderPublicKey: macPrivate.publicKey.x963Representation, privateKey: phonePrivate, workspaceID: fixture.workspaceID)
    #expect(openedByPhone == payload)

    var tampered = fromPhone.ciphertext
    tampered[tampered.startIndex] ^= 1
    #expect(throws: (any Error).self) {
        try RelayCryptography.open(RelaySealedData(nonce: fromPhone.nonce, ciphertext: tampered), senderPublicKey: phonePrivate.publicKey.x963Representation, privateKey: macPrivate, workspaceID: fixture.workspaceID)
    }
}

private struct CryptoFixture: Decodable {
    let workspaceID: String
    let macPrivateKey: String
    let phonePrivateKey: String
    let nonce: String
    let plaintext: String
    let macPublicKey: String
    let phonePublicKey: String
    let ciphertext: String
}

private func decode(_ value: String) -> Data {
    var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = normalized.count % 4
    if remainder != 0 { normalized += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: normalized) ?? Data()
}

private func encode(_ value: Data) -> String {
    value.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
