import Foundation

public enum SpeechRuntimeResolver {
    public static func whisperExecutable(
        isBundled: Bool,
        bundledExecutable: URL,
        environmentPath: String?,
        developmentFallback: URL?,
        isExecutable: (String) -> Bool
    ) -> URL? {
        if isBundled {
            return isExecutable(bundledExecutable.path) ? bundledExecutable : nil
        }

        if let environmentPath, environmentPath.hasPrefix("/"), isExecutable(environmentPath) {
            return URL(fileURLWithPath: environmentPath)
        }
        if let developmentFallback, isExecutable(developmentFallback.path) {
            return developmentFallback
        }
        return nil
    }
}
