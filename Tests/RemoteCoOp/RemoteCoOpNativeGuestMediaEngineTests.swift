//  The native guest's media engine. Audio and video share one UDP port, but they must not share one
//  serial queue: a hardware decode runs to completion on the calling thread, so a single queue puts
//  every audio chunk behind a frame's decode time.
//

import Foundation
import Testing
@testable import OpenNOW

@Suite("Remote Co-Op native guest media engine", .serialized)
struct RemoteCoOpNativeGuestMediaEngineTests {
    /// Occupies the video queue the way an in-flight hardware decode does: nothing else dispatched to
    /// it runs until the returned release is signalled.
    private func occupy(_ queue: DispatchQueue) -> (occupied: DispatchSemaphore, release: DispatchSemaphore) {
        let occupied = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            queue.sync {
                occupied.signal()
                release.wait()
            }
        }
        return (occupied, release)
    }

    /// Four frames of stereo silence, packetized the way the host sends game audio.
    private func audioDatagram() -> Data {
        let payload = Data(repeating: 0, count: 8)
        let header = OPNRemoteCoOpAudioPacket.Header(sequence: 1,
                                                     timestampNanoseconds: 0,
                                                     sampleRate: 48_000,
                                                     channels: 2,
                                                     frameCount: 4,
                                                     payloadLength: UInt16(payload.count))
        return OPNRemoteCoOpAudioPacket.encode(header, payload: payload)
    }

    @Test func guestAudioIsNotSerialisedBehindVideoDecode() {
        let videoQueue = DispatchQueue(label: "test.remote-coop.guest-video")
        let engine = RemoteCoOpNativeGuestMediaEngine(queue: videoQueue)
        let video = occupy(videoQueue)
        defer {
            video.release.signal()
            engine.stop()
        }
        #expect(video.occupied.wait(timeout: .now() + 5) == .success)

        engine.ingest(audioDatagram())

        // The audio chunk is accepted while the video queue is still held: a shared queue could only
        // reach it after the blocking decode returned.
        let deadline = Date().addingTimeInterval(2)
        while engine.audioChunkCount == 0, Date() < deadline { usleep(1_000) }
        #expect(engine.audioChunkCount == 1)
    }

    @Test func guestStopDoesNotWaitForAnInFlightDecode() {
        let videoQueue = DispatchQueue(label: "test.remote-coop.guest-video-stop")
        let engine = RemoteCoOpNativeGuestMediaEngine(queue: videoQueue)
        let video = occupy(videoQueue)
        #expect(video.occupied.wait(timeout: .now() + 5) == .success)

        let started = Date()
        engine.stop()
        let elapsed = Date().timeIntervalSince(started)
        video.release.signal()
        #expect(elapsed < 0.5)
    }
}
