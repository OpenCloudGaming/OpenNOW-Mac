import Testing
@testable import OpenNOW

/// PiP is deliberately never frontmost, so the frontmost input gate has to exempt exactly one
/// thing: the gamepad, and only while the mode is on. Keyboard and mouse stay gated - the user is
/// typing and clicking in whatever app they moved to, and that must not reach the game.
@MainActor
@Suite struct PictureInPictureInputRoutingTests {
    private let timestamp = MediaTimestamp(nanoseconds: 1)

    @Test func onlyTheGamepadPassesTheFrontmostGateInPictureInPicture() {
        let gamepad = UserInputEvent.gamepad(GamepadState(deviceID: "pad", playerIndex: 0, timestamp: timestamp))
        let keyboard = UserInputEvent.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: 0, scanCode: 0, isPressed: true, timestamp: timestamp))
        let mouse = UserInputEvent.mouse(.button(deviceID: "mouse", button: .left, isPressed: true, timestamp: timestamp))

        #expect(NativeNVSTHostViewModel.acceptsWhileNotFrontmost(gamepad, isPictureInPictureMode: true))
        #expect(!NativeNVSTHostViewModel.acceptsWhileNotFrontmost(keyboard, isPictureInPictureMode: true))
        #expect(!NativeNVSTHostViewModel.acceptsWhileNotFrontmost(mouse, isPictureInPictureMode: true))
        // Outside PiP nothing is exempt: losing focus ends stream input, as it always has.
        #expect(!NativeNVSTHostViewModel.acceptsWhileNotFrontmost(gamepad, isPictureInPictureMode: false))
        #expect(!NativeNVSTHostViewModel.acceptsWhileNotFrontmost(keyboard, isPictureInPictureMode: false))
        #expect(!NativeNVSTHostViewModel.acceptsWhileNotFrontmost(mouse, isPictureInPictureMode: false))
    }
}
