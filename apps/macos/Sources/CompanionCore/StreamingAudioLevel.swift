import Foundation

/// A thread-safe scalar snapshot for audio callbacks and the main-actor UI poller.
/// The real-time callback never reaches into the actor-isolated voice controller.
public final class StreamingAudioLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var latestDB = -160.0

    public init() {}

    public func publish(_ levelDB: Double) {
        lock.lock()
        latestDB = levelDB.isFinite ? max(-160, min(0, levelDB)) : -160
        lock.unlock()
    }

    public func load() -> Double {
        lock.lock()
        let levelDB = latestDB
        lock.unlock()
        return levelDB
    }
}
