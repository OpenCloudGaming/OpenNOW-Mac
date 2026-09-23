//  The native NVST transport's half of Instant Replay: starting, stopping and saving the rolling
//  window, and bridging its state back to the host.
//

import Foundation

extension NvstBifrostFreeTransport {
    public func startReplayBuffer(configuration: StreamReplayBufferConfiguration) async -> Bool {
        guard connection != nil else { return false }
        replayBuffer.start(configuration: configuration)
        logger?("NVST instant replay buffering \(Int(configuration.windowSeconds))s window at \(configuration.recording.width)x\(configuration.recording.height)")
        return true
    }

    public func stopReplayBuffer() async {
        replayBuffer.stop()
    }

    public func saveReplayClip() async {
        replayBuffer.saveClip()
    }

    public func setReplayBufferStateHandler(_ handler: (@MainActor @Sendable (StreamReplayBufferState) -> Void)?) async {
        replayBuffer.onStateChanged = handler
    }
}
