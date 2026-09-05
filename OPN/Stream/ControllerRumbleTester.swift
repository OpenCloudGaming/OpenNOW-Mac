//  A settings-page rumble check: pulses every attached pad the way a seat's `0x010b` command
//  would, so a silent pad in a game can be told apart from a pad that never rumbles at all.
//

import CoreHaptics
import Foundation
import GameController

@MainActor
public enum ControllerRumbleTester {
    public static let pulseMilliseconds = 450
    public static let amplitude: UInt16 = 0xc000

    /// What one pulse reached, for the settings row's status text.
    public struct Result: Equatable, Sendable {
        public var gameControllerPads = 0
        public var padsWithoutHaptics = 0
        public var steamControllers = 0

        public var summary: String {
            var parts: [String] = []
            if steamControllers > 0 { parts.append("\(steamControllers) Steam Controller\(steamControllers == 1 ? "" : "s")") }
            if gameControllerPads > 0 { parts.append("\(gameControllerPads) gamepad\(gameControllerPads == 1 ? "" : "s")") }
            if parts.isEmpty {
                return padsWithoutHaptics > 0
                    ? "Connected pad reports no rumble motors"
                    : "No controller connected"
            }
            return "Pulsed " + parts.joined(separator: " and ")
        }
    }

    private static var engines: [CHHapticEngine] = []

    /// Pulses both motors of every connected pad for `pulseMilliseconds`, at the user's rumble
    /// ceiling — the same strength a full-scale seat command would reach the pad with.
    @discardableResult
    public static func pulseAllControllers() -> Result {
        var result = Result()
        let scaled = ControllerRumblePreference.scaled(amplitude)
        for deviceID in SteamControllerHIDMonitor.shared.activeDeviceIDs {
            pulseSteamController(deviceID, left: scaled, right: scaled)
            result.steamControllers += 1
        }
        for controller in GCController.controllers() {
            guard let haptics = controller.haptics else {
                result.padsWithoutHaptics += 1
                continue
            }
            if pulse(haptics: haptics, amplitude: scaled) { result.gameControllerPads += 1 }
        }
        return result
    }

    /// One Steam Controller, either or both motors, then off after the pulse.
    public static func pulseSteamController(_ deviceID: InputDeviceID, left: UInt16, right: UInt16) {
        SteamControllerHIDMonitor.shared.sendRumble(deviceID: deviceID, leftAmplitude: left, rightAmplitude: right)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(pulseMilliseconds))
            SteamControllerHIDMonitor.shared.sendRumble(deviceID: deviceID, leftAmplitude: 0, rightAmplitude: 0)
        }
    }

    private static func pulse(haptics: GCDeviceHaptics, amplitude: UInt16) -> Bool {
        guard amplitude > 0 else { return true }
        let localities: [GCHapticsLocality] = haptics.supportedLocalities.contains(.leftHandle) && haptics.supportedLocalities.contains(.rightHandle)
            ? [.leftHandle, .rightHandle]
            : [.default]
        var played = false
        for locality in localities {
            guard let engine = haptics.createEngine(withLocality: locality) else { continue }
            do {
                engine.isAutoShutdownEnabled = false
                try engine.start()
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(amplitude) / Float(UInt16.max)),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                    ],
                    relativeTime: 0,
                    duration: TimeInterval(pulseMilliseconds) / 1_000
                )
                let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
                try player.start(atTime: 0)
                played = true
                // Kept alive until the pattern has finished; stopping the engine early cuts the pulse.
                engines.append(engine)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(pulseMilliseconds + 200))
                    try? await engine.stop()
                    engines.removeAll { $0 === engine }
                }
            } catch {
                engine.stop(completionHandler: nil)
            }
        }
        return played
    }
}
