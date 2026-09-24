import Foundation

/// A locked hand-off for decoded guest frames: the view's Metal surface sets the sink, and the media
/// connection feeds it from its own queue. A closure property on the view model would be a data race
/// between those two threads; this is one box with one lock.
final class RemoteCoOpNativeFrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (OPNVideoFrame) -> Void)?

    func set(_ sink: (@Sendable (OPNVideoFrame) -> Void)?) {
        lock.lock(); self.sink = sink; lock.unlock()
    }

    func send(_ frame: OPNVideoFrame) {
        lock.lock()
        let sink = sink
        lock.unlock()
        sink?(frame)
    }
}
