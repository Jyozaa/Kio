import Foundation

/// The bounded low-risk vocabulary that may be committed from a stable
/// streaming hypothesis before the final utterance is available.
public enum SemanticVoiceStepKind: String, Sendable {
    case ensureApp
    case webSearch
    case navigate
    case createNote
    case createEmailDraft
    case setField
    case mediaState
    case newTab
    case capturePhoto
}

public struct SemanticVoiceStep: Hashable, Sendable {
    public let id: String
    public let kind: SemanticVoiceStepKind
    /// A semantic argument used to reconcile an early step with the final
    /// transcript. It is not an execution selector or model-generated value.
    public let argument: String
    /// The exact spoken clause whose stable hypothesis authorized this step.
    /// Keeping this separate from `argument` lets the final transcript retain
    /// every later instruction when it is reconciled with early execution.
    public let sourceText: String

    public init(id: String, kind: SemanticVoiceStepKind, argument: String, sourceText: String? = nil) {
        self.id = id
        self.kind = kind
        self.argument = argument
        self.sourceText = sourceText ?? argument
    }
}

public enum SemanticVoiceStepParser {
    /// Parse only a safe, complete early step. The final command still goes
    /// through the normal Python planner and its execution policy checks.
    public static func parse(_ text: String) -> SemanticVoiceStep? {
        parseAll(text).first
    }

    /// Parse complete safe clauses in utterance order. Streaming transcripts
    /// are cumulative, so each clause has its own text for later reconciliation.
    public static func parseAll(_ text: String) -> [SemanticVoiceStep] {
        let clauses = splitCommand(text)
        var seen = Set<String>()
        return clauses.compactMap { source in
            guard let step = parseSingle(source), seen.insert(step.id).inserted else { return nil }
            return step
        }
    }

    private static func parseSingle(_ text: String) -> SemanticVoiceStep? {
        var words = tokenize(text)
        guard !containsNegation(words) else { return nil }
        stripGenericPrefix(from: &words)
        guard !words.isEmpty else { return nil }
        stripPoliteSuffix(from: &words)
        guard !words.isEmpty else { return nil }

        if words.starts(with: ["open", "a", "new", "tab"])
            || words.starts(with: ["open", "new", "tab"])
            || words == ["new", "tab"] {
            return SemanticVoiceStep(
                id: "new_tab",
                kind: .newTab,
                argument: clause(words),
                sourceText: sourceClause(text)
            )
        }

        if let destination = spokenDestination(in: words) {
            return SemanticVoiceStep(
                id: "navigate:\(destination)",
                kind: .navigate,
                argument: destination,
                sourceText: sourceClause(text)
            )
        }

        if ["open", "launch", "bring", "show"].contains(words[0]) {
            return appStep(from: words, sourceText: sourceClause(text))
        }

        if let search = searchQuery(in: words) {
            guard !search.isEmpty else { return nil }
            return SemanticVoiceStep(
                id: "web_search:\(search)",
                kind: .webSearch,
                argument: search,
                sourceText: sourceClause(text)
            )
        }

        if let state = mediaState(in: words) {
            return SemanticVoiceStep(
                id: "media_state:\(state)",
                kind: .mediaState,
                argument: clause(words),
                sourceText: sourceClause(text)
            )
        }

        if let assignment = fieldAssignment(in: words) {
            return SemanticVoiceStep(
                id: "set_field:\(assignment.field):\(assignment.value)",
                kind: .setField,
                argument: clause(words),
                sourceText: sourceClause(text)
            )
        }

        if words.contains(where: { ["draft", "compose", "write"].contains($0) }),
           words.contains(where: { ["email", "mail"].contains($0) }),
           let address = words.first(where: { isEmail($0) }) {
            return SemanticVoiceStep(
                id: "create_email_draft:\(address)",
                kind: .createEmailDraft,
                argument: clause(words),
                sourceText: sourceClause(text)
            )
        }

        if words.contains(where: { ["capture", "take"].contains($0) }),
           words.contains(where: { ["picture", "photo", "photograph"].contains($0) }) {
            return SemanticVoiceStep(
                id: "capture_photo",
                kind: .capturePhoto,
                argument: clause(words),
                sourceText: sourceClause(text)
            )
        }

        if words.contains(where: { ["create", "make", "new"].contains($0) }),
           words.contains(where: { ["note", "notes"].contains($0) }) {
            return SemanticVoiceStep(
                id: "create_note",
                kind: .createNote,
                argument: clause(words),
                sourceText: sourceClause(text)
            )
        }

        guard ["open", "launch", "bring", "show", "start"].contains(words[0]) else {
            return nil
        }

        var appWords = Array(words.dropFirst())
        if words[0] == "show", appWords.first == "me" { appWords.removeFirst() }
        if appWords.first == "up" { appWords.removeFirst() }
        if let index = appWords.firstIndex(where: { $0 == "and" || $0 == "then" }) {
            appWords = Array(appWords[..<index])
        }
        while ["please", "up", "app", "application"].contains(appWords.last ?? "") {
            appWords.removeLast()
        }
        if appWords.count >= 2, appWords.suffix(2).elementsEqual(["for", "me"]) {
            appWords.removeLast(2)
        }
        if ["the", "a", "an"].contains(appWords.first ?? "") { appWords.removeFirst() }
        guard !appWords.isEmpty else { return nil }

        let app = normalized(appWords.joined(separator: " "))
        guard app.count >= 2,
              !["playing", "writing", "typing", "a new tab", "new tab"].contains(app) else {
            return nil
        }
        return SemanticVoiceStep(
            id: "ensure_app:\(app)",
            kind: .ensureApp,
            argument: app,
            sourceText: sourceClause(text)
        )
    }

    private static func splitCommand(_ text: String) -> [String] {
        // Split only when a conjunction is followed by a recognizable action
        // start. This preserves ordinary query text such as "salt and pepper".
        let pattern = #"(?i)\s+(?:and\s+then|after\s+that|then|and)\s+(?=(?:(?:once\s+you(?:'re|’re|\s+are)\s+there[,]?\s*)?)(?:open|launch|bring|show|search|google|look\s+up|play|pause|resume|start\s+playing|create|make|new|draft|compose|write|put|type|enter|take|capture|name\s+it)\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return [text] }
        var parts: [String] = []
        var start = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let part = String(text[start..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { parts.append(part) }
            start = matchRange.upperBound
        }
        let tail = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }
        return parts.isEmpty ? [text] : parts
    }

    private static func stripGenericPrefix(from words: inout [String]) {
        if words.count >= 2, words[0] == "hey", words[1] == "kio" {
            words.removeFirst(2)
        }
        while let first = words.first,
              ["alright", "okay", "now", "then", "and", "please"].contains(first) {
            words.removeFirst()
        }
        if words.count >= 2,
           ["can", "could", "would"].contains(words[0]),
           words[1] == "you" {
            words.removeFirst(2)
        }
        if words.starts(with: ["once", "youre", "there"]) {
            words.removeFirst(3)
        }
        if words.first == "please" { words.removeFirst() }
    }

    private static func stripPoliteSuffix(from words: inout [String]) {
        if words.count >= 2, words.suffix(2).elementsEqual(["for", "me"]) {
            words.removeLast(2)
        }
        while words.last == "please" { words.removeLast() }
    }

    private static func searchQuery(in words: [String]) -> String? {
        var queryStart: Int?
        if words.starts(with: ["search", "google", "for"]) {
            queryStart = 3
        } else if words.starts(with: ["search", "google"]) {
            queryStart = 2
        } else if words.starts(with: ["search", "for"]) {
            queryStart = 2
        } else if words.first == "search" {
            queryStart = 1
        } else if words.starts(with: ["google", "search"]) {
            queryStart = 2
        } else if words.starts(with: ["look", "up"]) {
            queryStart = 2
            if words.dropFirst(2).first == "for" { queryStart = 3 }
        }
        guard let queryStart, queryStart < words.count else { return nil }
        let query = normalized(words.dropFirst(queryStart).joined(separator: " "))
        return query.count >= 2 ? query : nil
    }

    private static func spokenDestination(in words: [String]) -> String? {
        var destination = words
        if destination.first == "open" { destination.removeFirst() }
        if destination.first == "up" { destination.removeFirst() }
        if destination.starts(with: ["go", "to"]) { destination.removeFirst(2) }
        if destination.first == "visit" { destination.removeFirst() }
        guard let dot = destination.firstIndex(of: "dot"), dot > 0, dot + 1 < destination.count else {
            return nil
        }
        let host = destination.enumerated().map { index, word in index == dot ? "." : word }.joined()
        guard host.range(
            of: #"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"#,
            options: .regularExpression
        ) != nil else { return nil }
        return "https://\(host)"
    }

    private static func mediaState(in words: [String]) -> String? {
        if words.starts(with: ["start", "playing"]) { return "playing" }
        if ["pause", "play", "resume"].contains(words.first ?? "") {
            return words[0] == "pause" ? "paused" : "playing"
        }
        if words.first == "press" {
            let target = Array(words.dropFirst()).filter { $0 != "the" }
            if target.first == "pause" { return "paused" }
            if target.first == "play" { return "playing" }
        }
        return nil
    }

    private static func containsNegation(_ words: [String]) -> Bool {
        if words.contains(where: { ["dont", "never", "without"].contains($0) }) { return true }
        return zip(words, words.dropFirst()).contains { pair in
            pair.0 == "do" && pair.1 == "not"
        }
    }

    private static func fieldAssignment(in words: [String]) -> (field: String, value: String)? {
        var content = words
        if content.starts(with: ["inside", "this", "new", "note"])
            || content.starts(with: ["inside", "this", "note"])
            || content.starts(with: ["in", "this", "new", "note"]) {
            if let note = content.firstIndex(where: { ["note", "document"].contains($0) }) {
                content = Array(content.dropFirst(note + 1))
            }
        }
        if content.starts(with: ["lets"]) { content.removeFirst() }

        if content.starts(with: ["call", "it"]) || content.starts(with: ["name", "it"]) {
            let value = normalized(content.dropFirst(2).joined(separator: " "))
            return value.isEmpty ? nil : ("title", value)
        }
        if content.first == "make" || content.first == "set" {
            var tail = Array(content.dropFirst())
            if tail.first == "the" { tail.removeFirst() }
            if tail.first == "title" {
                tail.removeFirst()
                if tail.first == "field" { tail.removeFirst() }
                if ["say", "to", "as"].contains(tail.first ?? "") { tail.removeFirst() }
                let value = normalized(tail.joined(separator: " "))
                return value.isEmpty ? nil : ("title", value)
            }
            if tail.first == "subject" {
                tail.removeFirst()
                if tail.first == "field" { tail.removeFirst() }
                if tail.first == "to" { tail.removeFirst() }
                let value = normalized(tail.joined(separator: " "))
                return value.isEmpty ? nil : ("subject", value)
            }
        }
        if ["write", "put", "type", "enter"].contains(content.first ?? "") {
            let tail = Array(content.dropFirst())
            guard let divider = tail.firstIndex(where: { ["in", "into", "inside"].contains($0) }),
                  divider > 0 else { return nil }
            let destination = Array(tail.dropFirst(divider + 1))
            guard destination.contains(where: { ["body", "note", "document"].contains($0) })
                || destination.starts(with: ["it"]) else { return nil }
            let value = normalized(tail.prefix(divider).joined(separator: " "))
            return value.isEmpty ? nil : ("body", value)
        }
        return nil
    }

    private static func isEmail(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func appStep(from words: [String], sourceText: String) -> SemanticVoiceStep? {
        var appWords = Array(words.dropFirst())
        if words[0] == "show", appWords.first == "me" { appWords.removeFirst() }
        if appWords.first == "up" { appWords.removeFirst() }
        if let index = appWords.firstIndex(where: { $0 == "and" || $0 == "then" }) {
            appWords = Array(appWords[..<index])
        }
        while ["please", "up", "app", "application"].contains(appWords.last ?? "") {
            appWords.removeLast()
        }
        if appWords.count >= 2, appWords.suffix(2).elementsEqual(["for", "me"]) {
            appWords.removeLast(2)
        }
        if ["the", "a", "an"].contains(appWords.first ?? "") { appWords.removeFirst() }
        guard !appWords.isEmpty else { return nil }

        let app = normalized(appWords.joined(separator: " "))
        guard app.count >= 2,
              !["playing", "writing", "typing", "a new tab", "new tab"].contains(app),
              !(appWords.count >= 3 && appWords[1] == "dot" && appWords[2] == "com") else {
            return nil
        }
        return SemanticVoiceStep(
            id: "ensure_app:\(app)",
            kind: .ensureApp,
            argument: app,
            sourceText: sourceText
        )
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .map { $0.replacingOccurrences(of: "you're", with: "youre") }
            .map { $0.replacingOccurrences(of: "let's", with: "lets") }
            .map { $0.replacingOccurrences(of: "let’s", with: "lets") }
            .map { $0.replacingOccurrences(of: "don't", with: "dont") }
            .map { $0.replacingOccurrences(of: "don’t", with: "dont") }
            .filter { !$0.isEmpty }
    }

    private static func clause(_ words: [String]) -> String {
        normalized(words.joined(separator: " "))
    }

    private static func sourceClause(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
