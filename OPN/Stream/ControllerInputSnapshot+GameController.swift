import GameController

extension ControllerInputSnapshot {
    init(gamepad: GCExtendedGamepad) {
        self.init(
            buttons: NativeGamepadMonitor.buttons(from: gamepad),
            leftTrigger: gamepad.leftTrigger.value, rightTrigger: gamepad.rightTrigger.value,
            leftStickX: gamepad.leftThumbstick.xAxis.value, leftStickY: gamepad.leftThumbstick.yAxis.value,
            rightStickX: gamepad.rightThumbstick.xAxis.value, rightStickY: gamepad.rightThumbstick.yAxis.value
        )
        if let dualShock = gamepad as? GCDualShockGamepad {
            touchpad = ControllerTrackpadState(
                x: dualShock.touchpadPrimary.xAxis.value, y: dualShock.touchpadPrimary.yAxis.value,
                touched: dualShock.touchpadButton.isTouched, pressed: dualShock.touchpadButton.isPressed
            )
        }
    }
}
