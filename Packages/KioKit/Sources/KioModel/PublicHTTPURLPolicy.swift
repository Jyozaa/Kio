import Darwin
import Foundation
import KioCore

public enum PublicHTTPURLPolicy {
    public static func validate(_ rawValue: String) throws -> URL {
        try publicHTTPURL(rawValue, resolveDNS: true)
    }

    public static func publicHTTPURL(_ rawValue: String, resolveDNS: Bool) throws -> URL {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2_048 else { throw invalidURL() }
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard var components = URLComponents(string: candidate), let scheme = components.scheme?.lowercased() else { throw invalidURL() }
        components.scheme = scheme
        guard let url = components.url, isHTTPURL(url), components.user == nil, components.password == nil,
              (components.host?.count ?? 0) <= 253, (components.port == nil || (1...65_535).contains(components.port!)) else { throw invalidURL() }
        try validatePublicHost(url.host ?? "", resolveDNS: resolveDNS)
        return url
    }

    public static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }

    public static func isSafePublicHTTPURL(_ url: URL) -> Bool {
        guard isHTTPURL(url) else { return false }
        return (try? validatePublicHost(url.host ?? "", resolveDNS: false)) != nil
    }

    public static func validatePublicHost(_ source: String, resolveDNS: Bool = true) throws {
        let host = source.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        guard !host.isEmpty,
              !["localhost", "localhost.localdomain", "local", "internal", "home.arpa"].contains(host),
              !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.hasSuffix(".internal") else { throw invalidURL() }
        if let bytes = ipv4Bytes(host) {
            guard isPublicIPv4(bytes) else { throw invalidURL() }
            return
        }
        if let bytes = ipv6Bytes(host) {
            guard isPublicIPv6(bytes) else { throw invalidURL() }
            return
        }
        if !resolveDNS { return }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG
        var result: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString { getaddrinfo($0, nil, &hints, &result) }
        guard status == 0, let first = result else { throw invalidURL() }
        defer { freeaddrinfo(first) }
        var foundPublic = false
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let entry = current {
            if entry.pointee.ai_family == AF_INET, let address = entry.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee.sin_addr }) {
                let bytes = withUnsafeBytes(of: address.s_addr) { Array($0) }
                guard isPublicIPv4(bytes) else { throw invalidURL() }
                foundPublic = true
            } else if entry.pointee.ai_family == AF_INET6, let address = entry.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in6.self, capacity: 1, { $0.pointee.sin6_addr }) {
                let bytes = withUnsafeBytes(of: address) { Array($0) }
                guard isPublicIPv6(bytes) else { throw invalidURL() }
                foundPublic = true
            }
            current = entry.pointee.ai_next
        }
        guard foundPublic else { throw invalidURL() }
    }

    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var address = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: address.s_addr) { Array($0) }
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    private static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let a = Int(bytes[0]), b = Int(bytes[1])
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && [0, 2, 168].contains(b) { return false }
        if a == 198 && (18...19).contains(b) { return false }
        if a == 198 && b == 51 && bytes[2] == 100 { return false }
        if a == 203 && b == 0 && bytes[2] == 113 { return false }
        return true
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) || (bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1) { return false }
        if bytes[0] & 0xFE == 0xFC || bytes[0] == 0xFF || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && (bytes[2] == 0x0D || bytes[2] == 0x00) { return false }
        let isIPv4Mapped = bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF
        let isIPv4Compatible = bytes[0..<12].allSatisfy({ $0 == 0 })
        if (isIPv4Mapped || isIPv4Compatible), !isPublicIPv4(Array(bytes[12...15])) { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x02 && !isPublicIPv4(Array(bytes[2...5])) { return false }
        if Array(bytes[0..<4]) == [0x00, 0x64, 0xFF, 0x9B] { return false }
        return true
    }

    private static func invalidURL() -> KioFailure {
        .invalidInput("Use a public http:// or https:// media URL. Local hosts, private IP ranges, credentials, and unsafe schemes are blocked.")
    }
}
