import Foundation
import KioCore
import KioModel

enum SessionIntegrationError: LocalizedError {
    case hookResourceMissing
    case existingOpenCodePlugin
    case invalidConfiguration(URL)
    var errorDescription: String? {
        switch self {
        case .hookResourceMissing: "Kio's session hook helper is missing from the app bundle. Rebuild Kio to restore it."
        case .existingOpenCodePlugin: "An OpenCode plugin named kio-sessions.js already exists. Rename or remove it before installing Kio's hook."
        case .invalidConfiguration(let url): "Kio could not read the existing hook settings at \(url.path). The file was left unchanged."
        }
    }
}

enum SessionIntegrationManager {
    static func isInstalled(_ provider: SessionProvider, resourcesURL: URL? = Bundle.main.resourceURL) -> Bool {
        guard let resourcesURL else { return false }
        let helper = resourcesURL.appendingPathComponent("SessionHooks/kio-session-hook.py").path
        if provider == .openCode {
            return FileManager.default.fileExists(atPath: openCodePlugin.path)
                && ((try? String(contentsOf: openCodePlugin, encoding: .utf8))?.contains("KIO_SESSIONS_PLUGIN") == true)
        }
        guard let config = configURL(for: provider), let data = try? Data(contentsOf: config),
              let body = String(data: data, encoding: .utf8) else { return false }
        return body.contains(helper)
    }

    static func install(_ provider: SessionProvider, resourcesURL: URL? = Bundle.main.resourceURL) throws {
        guard let resourcesURL else { throw SessionIntegrationError.hookResourceMissing }
        let helper = resourcesURL.appendingPathComponent("SessionHooks/kio-session-hook.py")
        guard FileManager.default.isReadableFile(atPath: helper.path) else { throw SessionIntegrationError.hookResourceMissing }
        if provider == .openCode { try installOpenCodePlugin(); return }
        guard let url = configURL(for: provider) else { throw SessionIntegrationError.invalidConfiguration(resourcesURL) }
        var root: [String: Any]
        if let data = try? Data(contentsOf: url) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SessionIntegrationError.invalidConfiguration(url)
            }
            root = object
        } else { root = [:] }

        if provider == .cursor { try addCursorHooks(root: &root, helper: helper) }
        else { try addClaudeOrCodexHooks(root: &root, provider: provider, helper: helper) }
        try save(root, to: url)
    }

    static func remove(_ provider: SessionProvider, resourcesURL: URL? = Bundle.main.resourceURL) throws {
        if provider == .openCode {
            guard FileManager.default.fileExists(atPath: openCodePlugin.path),
                  (try? String(contentsOf: openCodePlugin, encoding: .utf8))?.contains("KIO_SESSIONS_PLUGIN") == true else { return }
            try FileManager.default.removeItem(at: openCodePlugin)
            return
        }
        guard let resourcesURL, let url = configURL(for: provider), let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let helper = resourcesURL.appendingPathComponent("SessionHooks/kio-session-hook.py").path
        if provider == .cursor {
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for key in Array(hooks.keys) {
                hooks[key] = (hooks[key] as? [[String: Any]] ?? []).filter { !(($0["command"] as? String)?.contains(helper) ?? false) }
                if (hooks[key] as? [[String: Any]])?.isEmpty == true { hooks.removeValue(forKey: key) }
            }
            root["hooks"] = hooks
        } else {
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for key in Array(hooks.keys) {
                hooks[key] = (hooks[key] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                    var group = group
                    group["hooks"] = (group["hooks"] as? [[String: Any]] ?? []).filter { !(($0["command"] as? String)?.contains(helper) ?? false) }
                    return (group["hooks"] as? [[String: Any]])?.isEmpty == true ? nil : group
                }
                if (hooks[key] as? [[String: Any]])?.isEmpty == true { hooks.removeValue(forKey: key) }
            }
            root["hooks"] = hooks
        }
        try save(root, to: url)
    }

    private static func addClaudeOrCodexHooks(root: inout [String: Any], provider: SessionProvider, helper: URL) throws {
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let eventNames: [String]
        switch provider {
        case .claude: eventNames = ["SessionStart", "Notification", "Stop", "StopFailure", "SessionEnd"]
        case .codex: eventNames = ["SessionStart", "PermissionRequest", "Stop", "SessionEnd"]
        default: return
        }
        for name in eventNames {
            var groups = hooks[name] as? [[String: Any]] ?? []
            guard !groups.contains(where: { String(describing: $0).contains(helper.path) }) else { continue }
            let command = "/usr/bin/python3 \(shellQuote(helper.path)) \(provider.rawValue) \(name)"
            let handler: [String: Any] = ["type": "command", "command": command, "timeout": 5]
            groups.append(["matcher": "", "hooks": [handler]])
            hooks[name] = groups
        }
        root["hooks"] = hooks
    }

    private static func addCursorHooks(root: inout [String: Any], helper: URL) throws {
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for name in ["sessionStart", "sessionEnd", "stop"] {
            var values = hooks[name] as? [[String: Any]] ?? []
            guard !values.contains(where: { String(describing: $0).contains(helper.path) }) else { continue }
            let command = "/usr/bin/python3 \(shellQuote(helper.path)) cursor \(name)"
            values.append(["command": command, "timeout": 5])
            hooks[name] = values
        }
        root["version"] = root["version"] ?? 1
        root["hooks"] = hooks
    }

    private static func installOpenCodePlugin() throws {
        try FileManager.default.createDirectory(at: openCodePlugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: openCodePlugin.path),
           (try? String(contentsOf: openCodePlugin, encoding: .utf8))?.contains("KIO_SESSIONS_PLUGIN") != true {
            throw SessionIntegrationError.existingOpenCodePlugin
        }
        let source = """
        // KIO_SESSIONS_PLUGIN — lifecycle metadata only. Does not inspect message content.
        import fs from 'node:fs'
        import path from 'node:path'
        import os from 'node:os'
        export const KioSessions = async () => ({
          event: async ({ event }) => {
            const type = event?.type || ''
            const props = event?.properties || {}
            if (!/^session\\.(created|idle|status|error|deleted)$/.test(type) && type !== 'permission.asked') return
            const map = { 'session.created': 'started', 'session.idle': 'finished', 'session.error': 'failed', 'session.deleted': 'ended', 'permission.asked': 'needsInput' }
            let state = map[type]
            if (!state && type === 'session.status') state = props.status?.type === 'busy' ? 'activity' : (props.status?.type === 'idle' ? 'idle' : null)
            if (!state) return
            const session = props.info || props.session || props
            const directory = session.directory || session.cwd || ''
            const payload = { provider: 'openCode', event: state, session_id: props.sessionID || session.id || session.sessionID || '',
              event_id: `${session.id || ''}:${type}:${Date.now()}`, project_name: path.basename(directory) || 'Project', cwd: directory, timestamp: Date.now()/1000 }
            if (!payload.session_id) return
            const root = path.join(os.homedir(), 'Library/Application Support/Kio/Sessions/Inbox')
            fs.mkdirSync(root, { recursive: true, mode: 0o700 })
            const prior = fs.readdirSync(root).filter(name => name.endsWith('.json')).map(name => {
              const file = path.join(root, name); return { file, mtime: fs.statSync(file).mtimeMs }
            }).sort((a, b) => a.mtime - b.mtime)
            for (const item of prior.slice(0, Math.max(0, prior.length - 299))) fs.rmSync(item.file, { force: true })
            const target = path.join(root, `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}.json`)
            const temp = `${target}.tmp`
            fs.writeFileSync(temp, JSON.stringify(payload), { mode: 0o600 })
            fs.renameSync(temp, target)
          }
        })
        """
        try Data(source.utf8).write(to: openCodePlugin, options: .atomic)
    }

    private static func save(_ object: [String: Any], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("kio-backup")
            if !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: url, to: backup) }
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func configURL(for provider: SessionProvider) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return switch provider {
        case .claude: home.appendingPathComponent(".claude/settings.json")
        case .codex: home.appendingPathComponent(".codex/hooks.json")
        case .cursor: home.appendingPathComponent(".cursor/hooks.json")
        case .openCode: nil
        }
    }
    private static var openCodePlugin: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode/plugins/kio-sessions.js")
    }
}
