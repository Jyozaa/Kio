import Foundation

public struct EmbeddedDriverSpec: Equatable {
    public let executablePath: String
    public let socketPath: String
    public let hostBundleIdentifier: String
    public let allowExistingProfile: Bool

    public init(
        executablePath: String, socketPath: String, hostBundleIdentifier: String,
        allowExistingProfile: Bool = false
    ) {
        self.executablePath = executablePath
        self.socketPath = socketPath
        self.hostBundleIdentifier = hostBundleIdentifier
        self.allowExistingProfile = allowExistingProfile
    }

    public var daemonArguments: [String] {
        var arguments = ["serve", "--embedded", "--socket", socketPath, "--permission-mode", "standard"]
        if allowExistingProfile { arguments += ["--grant", "existing-profile"] }
        return arguments
    }

    public var environment: [String: String] {
        [
            "CUA_DRIVER_EMBEDDED": "1",
            "CUA_DRIVER_HOST_BUNDLE_ID": hostBundleIdentifier,
        ]
    }

    public static func make(
        executablePath: String?, socketPath: String?, hostBundleIdentifier: String?,
        allowExistingProfile: Bool = false
    ) -> EmbeddedDriverSpec? {
        guard let executablePath, executablePath.hasPrefix("/"),
              let socketPath, socketPath.hasPrefix("/"), socketPath.utf8.count < 100,
              let hostBundleIdentifier,
              hostBundleIdentifier.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
        else { return nil }
        return EmbeddedDriverSpec(
            executablePath: executablePath,
            socketPath: socketPath,
            hostBundleIdentifier: hostBundleIdentifier,
            allowExistingProfile: allowExistingProfile
        )
    }
}
