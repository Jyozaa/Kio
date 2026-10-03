import Foundation
import KioCore
import KioModel

public enum ReelURLReference {
    public static func makeArtifact(_ rawValue: String) throws -> ArtifactRef {
        let url = try PublicHTTPURLPolicy.publicHTTPURL(rawValue, resolveDNS: true)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kio/ReelInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data(url.absoluteString.utf8)
        let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("kio-url")
        try data.write(to: destination, options: .atomic)
        return ArtifactRef(displayName: url.host ?? "Media URL", kind: .url, fileURL: destination, sizeBytes: Int64(data.count))
    }

    public static func readURL(from artifact: ArtifactRef) throws -> URL {
        guard artifact.kind == .url, artifact.fileURL.pathExtension.lowercased() == "kio-url",
              artifact.sizeBytes <= 4_096,
              let value = try? String(contentsOf: artifact.fileURL, encoding: .utf8) else {
            throw KioFailure.invalidInput("This Reel URL reference is unavailable or malformed.")
        }
        return try PublicHTTPURLPolicy.publicHTTPURL(value, resolveDNS: true)
    }
}
