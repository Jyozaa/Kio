import Foundation

/// Answers a small set of read-only conversational requests without invoking the tool planner.
public struct FastPathResponseResolver: Sendable {
    public init() {}

    public func response(to request: String) -> String? {
        let words = Set(request.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        guard words.contains("mac"), words.contains("online"),
              words.contains("is") || words.contains("check") || words.contains("whether") || words.contains("status") else {
            return nil
        }
        return "Your Mac is online—it received this request just now."
    }
}
