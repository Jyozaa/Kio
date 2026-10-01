import Foundation

/// An explicit, one-shot interpretation of data the user pasted into Kio.
public enum ClipboardInput: Sendable, Equatable {
    case files([URL])
    case image(Data)
    case webURL(String)
    case text(String)
}

public enum ClipboardInputResolver {
    /// Resolves only values supplied by the paste action. It never reads or
    /// monitors the system pasteboard itself.
    public static func resolve(
        fileURLs: [URL],
        imageData: Data?,
        urlString: String?,
        text: String?
    ) -> ClipboardInput? {
        let files = fileURLs.filter(\.isFileURL)
        if !files.isEmpty { return .files(files) }
        if let imageData, !imageData.isEmpty { return .image(imageData) }

        if let candidate = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), isHTTPURL(candidate) {
            return .webURL(candidate)
        }
        if let text, !text.isEmpty {
            let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isHTTPURL(candidate) { return .webURL(candidate) }
            return .text(text)
        }
        return nil
    }

    private static func isHTTPURL(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return false }
        return true
    }
}

public struct ClipboardComposerSubmission: Sendable, Equatable {
    public let request: String
    public let pastedText: String?

    public init(request: String, pastedText: String?) {
        self.request = request
        self.pastedText = pastedText
    }
}

public enum ClipboardComposerResolver {
    /// Removes only text Kio inserted through an explicit paste action, leaving
    /// the user's surrounding instruction as the task request.
    public static func resolve(message: String, pastedTexts: [String]) -> ClipboardComposerSubmission {
        var request = message
        var captured: [String] = []
        for text in pastedTexts where !text.isEmpty {
            guard let range = request.range(of: text) else { continue }
            request.replaceSubrange(range, with: " ")
            captured.append(text)
        }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":,–—-"))
        return ClipboardComposerSubmission(
            request: request.trimmingCharacters(in: separators),
            pastedText: captured.isEmpty ? nil : captured.joined(separator: "\n\n")
        )
    }
}

public enum InlineTextSubmissionResolver {
    /// Separates a clearly delimited text source from a PWA text instruction.
    /// Only plain text transformation requests are accepted; URLs stay on
    /// Scout's input path, and the caller still treats the source as untrusted.
    public static func resolve(message: String) -> ClipboardComposerSubmission? {
        guard message.count <= 2_000,
              message.range(of: #"(?i)\bhttps?://"#, options: .regularExpression) == nil,
              let boundary = message.firstIndex(where: { $0 == ":" || $0 == "\n" }) else { return nil }
        let instruction = String(message[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        let source = String(message[message.index(after: boundary)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !source.isEmpty else { return nil }

        let words = Set(instruction.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let hasTextOperation = !words.isDisjoint(with: [
            "summarize", "summarise", "summary", "rewrite", "rephrase", "proofread",
            "proofreading", "translate", "translation", "explain", "simplify", "markdown"
        ]) || (words.contains("key") && words.contains("points")) ||
            (words.contains("action") && (words.contains("item") || words.contains("items")))
        guard hasTextOperation else { return nil }
        return ClipboardComposerSubmission(request: instruction, pastedText: source)
    }
}
