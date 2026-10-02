import Foundation
import KioCore

public enum ReelRequestRouter {
    public static func plan(request: String, artifacts: [ArtifactRef]) -> TaskPlan? {
        let candidates = artifacts.filter { $0.kind == .url || $0.fileURL.pathExtension.lowercased() == "kio-reel-info" }
        guard (1...8).contains(candidates.count), candidates.count == artifacts.count else { return nil }
        let lower = request.lowercased()
        guard lower.range(of: #"\b(download|save|grab|acquire|get|fetch)\b"#, options: .regularExpression) != nil else { return nil }
        guard candidates.count == 1 else { return TaskPlan(request: request, steps: [], clarification: "Reel downloads one media URL at a time. Choose one URL.") }
        let operation: ToolOperation
        if lower.contains("subtitle") || lower.contains("captions") { operation = .downloadRemoteSubtitles }
        else if lower.contains("thumbnail") || lower.contains("cover image") { operation = .downloadRemoteThumbnail }
        else if lower.contains("gallery") || lower.contains("album") {
            return TaskPlan(request: request, steps: [], clarification: "Reel cannot download image galleries in this build. Choose a direct media URL instead.")
        }
        else if lower.contains("live") || lower.contains("livestream") || lower.contains("live stream") { operation = .downloadRemoteLive }
        else if lower.contains("audio") || lower.contains(" mp3") || lower.contains(" m4a") || lower.contains(" wav") || lower.contains(" flac") { operation = .downloadRemoteAudio }
        else { operation = .downloadRemoteVideo }
        let quality = qualityValue(in: lower)
        let format = formatValue(in: lower, audio: operation == .downloadRemoteAudio)
        let underspecified = candidates[0].kind == .url && operation == .downloadRemoteVideo && quality == nil && format == nil && !lower.contains("best quality")
        let selected = underspecified ? ToolOperation.inspectRemoteMedia : operation
        let args: ToolArguments = selected == .inspectRemoteMedia ? .none : .remoteMedia(quality: quality ?? (lower.contains("best quality") ? "best" : nil), format: format)
        return TaskPlan(request: request, steps: [TaskStep(operation: selected, source: .artifacts([candidates[0].id]), arguments: args)])
    }

    private static func qualityValue(in text: String) -> String? {
        if text.contains("best quality") || text.contains("best resolution") { return "best" }
        for value in [2160, 1440, 1080, 720, 480, 360] where text.contains("\(value)p") { return "\(value)p" }
        return nil
    }
    private static func formatValue(in text: String, audio: Bool) -> String? {
        let formats = audio ? ["mp3", "m4a", "wav", "flac"] : ["mp4", "webm", "mkv", "mov"]
        return formats.first { text.contains("\($0)") }
    }
}
