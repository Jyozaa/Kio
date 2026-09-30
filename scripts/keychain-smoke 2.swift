import Foundation

@main
struct KeychainSmoke {
    static func main() throws {
        let account = "self-test-" + UUID().uuidString
        defer { try? KeychainStore.delete(account: account) }
        try KeychainStore.save("harmless-test-value", account: account)
        guard try KeychainStore.read(account: account) == "harmless-test-value" else { fatalError("Keychain round trip failed") }
        try KeychainStore.save("replacement-test-value", account: account)
        guard try KeychainStore.read(account: account) == "replacement-test-value" else { fatalError("Keychain replacement failed") }
        try KeychainStore.delete(account: account)
        guard try KeychainStore.read(account: account) == nil else { fatalError("Keychain deletion failed") }
        print("Real Keychain save, retrieve, replace and delete passed; temporary account removed.")
    }
}
