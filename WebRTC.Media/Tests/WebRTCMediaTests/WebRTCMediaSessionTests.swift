import Foundation
import Testing
@testable import WebRTCMedia

@Suite("WebRTCMediaSession")
struct WebRTCMediaSessionTests {
    @Test("routes video frames to media subscribers")
    func routesVideoFrames() async {
        let session = WebRTCMediaSession()
        let stream = await session.mediaFrames()
        let frame = VideoFrame(
            trackID: "video-main",
            timestamp: MediaTimestamp(nanoseconds: 42),
            durationNanoseconds: 16_666_667,
            dimensions: VideoDimensions(width: 1920, height: 1080),
            pixelFormat: .nv12,
            payload: Data([1, 2, 3])
        )

        await session.publish(.video(frame))
        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()

        #expect(received == .video(frame))
    }

    @Test("routes gamepad events to input subscribers")
    func routesGamepadEvents() async {
        let session = WebRTCMediaSession()
        let stream = await session.inputEvents()
        let state = GamepadState(
            deviceID: "controller-1",
            playerIndex: 0,
            buttons: [.south, .rightShoulder],
            leftTrigger: 0.25,
            rightTrigger: 1.2,
            leftStickX: -1.4,
            leftStickY: 0.5,
            rightStickX: 0.25,
            rightStickY: -0.75,
            timestamp: MediaTimestamp(nanoseconds: 100)
        )

        await session.publish(.gamepad(state))
        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()

        #expect(received == .gamepad(state))
        #expect(state.rightTrigger == 1)
        #expect(state.leftStickX == -1)
    }
}
