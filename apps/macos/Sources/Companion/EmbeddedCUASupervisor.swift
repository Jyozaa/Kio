import CompanionCore
import Darwin
import Foundation

enum EmbeddedCUASupervisorError: LocalizedError {
    case missingExecutable
    case anotherKioInstance
    case unsafeRuntimeDirectory
    case invalidSocketPath
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .missingExecutable: "Kio's embedded computer runtime is missing. Reinstall Kio."
        case .anotherKioInstance: "Kio is already running. Switch to the open Kio app."
        case .unsafeRuntimeDirectory: "Kio could not create a private computer-use session."
        case .invalidSocketPath: "Kio could not create a valid private driver endpoint."
        case .launchFailed: "Kio could not start its local computer runtime."
        }
    }
}

@MainActor
final class EmbeddedCUASupervisor {
    static let shared = EmbeddedCUASupervisor()

    private(set) var socketPath: String?
    var onUnexpectedExit: (() -> Void)?

    private var process: Process?
    private var runtimeDirectory: URL?
    private var lockDescriptor: Int32 = -1
    private var stopping = false
    private var generation = UUID()

    func startIfBundled(allowExistingProfile: Bool = false) throws -> String? {
        guard HelperConfiguration.bundled else { return nil }
        if let process, process.isRunning, let socketPath { return socketPath }
        process = nil
        guard let executable = HelperConfiguration.cuaDriverExecutable,
              FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw EmbeddedCUASupervisorError.missingExecutable }

        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Kio", isDirectory: true)
        if lockDescriptor < 0 {
            try ensurePrivateDirectory(base)
            try acquireHostLock(in: base)
            removeStaleSessions(in: base)
        }
        let leaf = runtimeDirectory ?? base.appendingPathComponent(
            "driver-\(getpid())", isDirectory: true
        )
        try ensurePrivateDirectory(leaf)
        let socket = socketPath ?? leaf.appendingPathComponent("mcp.sock").path
        guard let spec = EmbeddedDriverSpec.make(
            executablePath: executable.path,
            socketPath: socket,
            hostBundleIdentifier: Bundle.main.bundleIdentifier,
            allowExistingProfile: allowExistingProfile
        ) else {
            try? FileManager.default.removeItem(at: leaf)
            releaseHostLock()
            throw EmbeddedCUASupervisorError.invalidSocketPath
        }

        let child = Process()
        child.executableURL = executable
        child.arguments = spec.daemonArguments
        child.environment = daemonEnvironment(spec.environment)
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice

        let childGeneration = UUID()
        generation = childGeneration
        runtimeDirectory = leaf
        socketPath = socket
        process = child
        child.terminationHandler = { [weak self] terminated in
            let pid = terminated.processIdentifier
            let status = terminated.terminationStatus
            Task { @MainActor in
                self?.didTerminate(generation: childGeneration, pid: pid, status: status)
            }
        }
        do {
            try child.run()
        } catch {
            process = nil
            cleanupProcessState()
            releaseHostLock()
            throw EmbeddedCUASupervisorError.launchFailed
        }
        return socket
    }

    func stop() {
        stopping = true
        generation = UUID()
        terminateCurrentDaemon()
        self.process = nil
        cleanupProcessState()
        releaseHostLock()
        stopping = false
    }

    func restart(allowExistingProfile: Bool = false) throws -> String? {
        guard HelperConfiguration.bundled else { return nil }
        stopping = true
        generation = UUID()
        terminateCurrentDaemon()
        if let socketPath { _ = unlink(socketPath) }
        process = nil
        stopping = false
        return try startIfBundled(allowExistingProfile: allowExistingProfile)
    }

    private func daemonEnvironment(_ driverEnvironment: [String: String]) -> [String: String] {
        var result = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
        ]
        result.merge(driverEnvironment) { _, new in new }
        return result
    }

    private func ensurePrivateDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch { throw EmbeddedCUASupervisorError.unsafeRuntimeDirectory }
        var metadata = Darwin.stat()
        guard lstat(directory.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(),
              chmod(directory.path, mode_t(S_IRWXU)) == 0
        else { throw EmbeddedCUASupervisorError.unsafeRuntimeDirectory }
    }

    private func acquireHostLock(in directory: URL) throws {
        let path = directory.appendingPathComponent("host.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw EmbeddedCUASupervisorError.unsafeRuntimeDirectory }
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            close(descriptor)
            throw EmbeddedCUASupervisorError.unsafeRuntimeDirectory
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw EmbeddedCUASupervisorError.anotherKioInstance
        }
        lockDescriptor = descriptor
    }

    private func removeStaleSessions(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("driver-") {
            var metadata = Darwin.stat()
            guard lstat(entry.path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_uid == getuid()
            else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func didTerminate(generation terminatedGeneration: UUID, pid: Int32, status: Int32) {
        guard generation == terminatedGeneration else { return }
        process = nil
        if let socketPath { _ = unlink(socketPath) }
        if !stopping { onUnexpectedExit?() }
        _ = pid
        _ = status
    }

    private func cleanupProcessState() {
        if let runtimeDirectory { try? FileManager.default.removeItem(at: runtimeDirectory) }
        runtimeDirectory = nil
        socketPath = nil
    }

    private func terminateCurrentDaemon() {
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1.5)
        while process.isRunning && Date() < deadline { usleep(25_000) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private func releaseHostLock() {
        guard lockDescriptor >= 0 else { return }
        _ = flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }
}
