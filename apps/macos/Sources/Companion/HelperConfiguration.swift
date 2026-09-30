import Foundation
import CompanionCore

enum HelperConfiguration {
    static var bundled: Bool { FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/python/bin/python3.12").path) }
    private static var developmentRoot: URL? {
        if let configured = ProcessInfo.processInfo.environment["COMPANION_ROOT"] {
            let url = URL(fileURLWithPath: configured).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("models/laya.json").path) { return url }
        }
        let rootMarker = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/KioDevelopmentRoot")
        if let configured = try? String(contentsOf: rootMarker, encoding: .utf8) {
            let url = URL(fileURLWithPath: configured.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("models/laya.json").path) { return url }
        }
        var candidate = Bundle.main.bundleURL
        for _ in 0..<4 { candidate.deleteLastPathComponent() }
        guard FileManager.default.fileExists(atPath: candidate.appendingPathComponent("models/laya.json").path),
              FileManager.default.fileExists(atPath: candidate.appendingPathComponent("agent/pyproject.toml").path)
        else { return nil }
        return candidate
    }

    static var sttExecutable: URL? {
        let bundleExecutable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/whisper-cli")
        let developmentFallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Kio/whisper-build/bin/whisper-cli")
        return SpeechRuntimeResolver.whisperExecutable(
            isBundled: bundled,
            bundledExecutable: bundleExecutable,
            environmentPath: ProcessInfo.processInfo.environment["KIO_STT_EXECUTABLE"],
            developmentFallback: developmentFallback
        ) { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var streamingSttExecutable: URL? {
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let bundled = helpers.appendingPathComponent("whisper-stream")
        let bundledSDL = helpers.appendingPathComponent("libSDL3.dylib")
        if FileManager.default.isExecutableFile(atPath: bundled.path),
           FileManager.default.fileExists(atPath: bundledSDL.path) { return bundled }
        let development = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Kio/whisper-build/bin/whisper-stream")
        let developmentSDL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KIO_SDL3_PREFIX"] ?? "/opt/homebrew/opt/sdl3")
            .appendingPathComponent("lib/libSDL3.0.dylib")
        if FileManager.default.isExecutableFile(atPath: development.path),
           FileManager.default.fileExists(atPath: developmentSDL.path) { return development }
        return nil
    }

    static var cuaDriverExecutable: URL? {
        guard bundled else { return nil }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cua-driver")
    }
    static var executable: URL? {
        if bundled { return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/python/bin/python3.12") }
        if let configured = ProcessInfo.processInfo.environment["KIO_HELPER_PYTHON"] {
            let url = URL(fileURLWithPath: configured)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Kio/development-venv/bin/python")
        return FileManager.default.isExecutableFile(atPath: fallback.path) ? fallback : nil
    }
    static var manifests: URL {
        if bundled { return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/models") }
        return developmentRoot?.appendingPathComponent("models") ?? URL(fileURLWithPath: ".").appendingPathComponent("models")
    }
    static func environment(cuaSocketPath: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "PYTHONPATH"); env.removeValue(forKey: "PYTHONHOME")
        env.removeValue(forKey: "KIO_STT_EXECUTABLE")
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        if bundled {
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            env["KIO_STT_EXECUTABLE"] = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/whisper-cli").path
            env["KIO_MODEL_MANIFEST"] = manifests.appendingPathComponent("laya.json").path
            if let cuaDriverExecutable, let cuaSocketPath {
                env["KIO_CUA_DRIVER_EXECUTABLE"] = cuaDriverExecutable.path
                env["KIO_CUA_SOCKET"] = cuaSocketPath
                env["KIO_CUA_HOST_BUNDLE_ID"] = Bundle.main.bundleIdentifier ?? "local.companion.dev"
            }
        } else {
            if let developmentRoot {
                env["COMPANION_ROOT"] = developmentRoot.path
                env["KIO_MODEL_MANIFEST"] = manifests.appendingPathComponent("laya.json").path
            }
            if let sttExecutable { env["KIO_STT_EXECUTABLE"] = sttExecutable.path }
        }
        if let key = try? KeychainStore.read() {
            env["GEMINI_API_KEY"] = key
            env["GEMINI_MODEL"] = UserDefaults.standard.string(forKey: "geminiModel")
        }
        return env
    }
}
