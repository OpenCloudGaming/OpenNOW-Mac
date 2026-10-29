import Testing
@testable import OpenNOW

@MainActor @Suite struct CouchCoopInputRoutingTests {
    private let gamepad = UserInputEvent.gamepad(GamepadState(deviceID: "pad", playerIndex: 0, timestamp: MediaTimestamp(nanoseconds: 0)))
    private let keyboard = UserInputEvent.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: 0, scanCode: 0, modifiers: [], isPressed: true, timestamp: MediaTimestamp(nanoseconds: 0)))
    private let mouse = UserInputEvent.mouse(.button(deviceID: "mouse", button: .left, isPressed: true, timestamp: MediaTimestamp(nanoseconds: 0)))

    @Test func padsPlayInTheBackgroundOnlyWithTheFlagAndASecondStream() {
        #expect(!OPNCouchCoopInputPolicy.allowsBackgroundGamepads(isFlagEnabled: false, liveStreamCount: 2))
        #expect(!OPNCouchCoopInputPolicy.allowsBackgroundGamepads(isFlagEnabled: true, liveStreamCount: 1))
        #expect(!OPNCouchCoopInputPolicy.allowsBackgroundGamepads(isFlagEnabled: true, liveStreamCount: 0))
        #expect(OPNCouchCoopInputPolicy.allowsBackgroundGamepads(isFlagEnabled: true, liveStreamCount: 2))
        #expect(OPNCouchCoopInputPolicy.allowsBackgroundGamepads(isFlagEnabled: true, liveStreamCount: 4))
    }

    @Test func aBackgroundWindowAcceptsItsPadsButNeverTheKeyboardOrMouse() {
        #expect(NativeNVSTHostViewModel.acceptsWhileNotFrontmost(gamepad, isPictureInPictureMode: false, allowsBackgroundGamepad: true))
        #expect(!NativeNVSTHostViewModel.acceptsWhileNotFrontmost(keyboard, isPictureInPictureMode: false, allowsBackgroundGamepad: true))
        #expect(!NativeNVSTHostViewModel.acceptsWhileNotFrontmost(mouse, isPictureInPictureMode: false, allowsBackgroundGamepad: true))
    }

    @Test func withoutCouchCoopOrPictureInPictureNothingPassesWhileNotFrontmost() {
        #expect(!NativeNVSTHostViewModel.acceptsWhileNotFrontmost(gamepad, isPictureInPictureMode: false, allowsBackgroundGamepad: false))
        #expect(!NativeNVSTHostViewModel.acceptsWhileNotFrontmost(gamepad, isPictureInPictureMode: false))
        #expect(NativeNVSTHostViewModel.acceptsWhileNotFrontmost(gamepad, isPictureInPictureMode: true))
        #expect(!NativeNVSTHostViewModel.acceptsWhileNotFrontmost(keyboard, isPictureInPictureMode: true, allowsBackgroundGamepad: true))
    }

    @Test func mappingsFollowABackgroundPadWhileTheOverlayAndRemoteGatesStillApply() {
        for overlay in [false, true] {
            for remote in [false, true] {
                let allowed = ControllerMappingFocusPolicy.allowsMappings(
                    appIsActive: false, windowIsKey: false, remoteInputEnabled: remote,
                    overlayCapturesInput: overlay, allowsBackgroundPads: true
                )
                #expect(allowed == (remote && !overlay))
                let withoutBackground = ControllerMappingFocusPolicy.allowsMappings(
                    appIsActive: false, windowIsKey: false, remoteInputEnabled: remote,
                    overlayCapturesInput: overlay, allowsBackgroundPads: false
                )
                #expect(!withoutBackground)
            }
        }
    }
}
