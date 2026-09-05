//  A client-side ceiling on rumble strength. Games scale some of their effects with their own
//  vibration setting and send others at full strength regardless (Streets of Rage 4's special
//  moves, 2026-09-05); this is the one knob that reaches everything the seat sends, on every pad.
//

import Foundation

public enum ControllerRumblePreference {
    public static let range = 0...100
    public static let step = 5
    private static let key = "OpenNOW.Controller.RumbleIntensityPercent"

    /// 0 silences every pad; 100 passes the seat's amplitudes through unchanged.
    public static func loadIntensityPercent() -> Int {
        guard let stored = OPNAppPreferenceStorage.standard.object(forKey: key) as? Int else { return 100 }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    public static func saveIntensityPercent(_ percent: Int) {
        OPNAppPreferenceStorage.standard.set(min(max(percent, range.lowerBound), range.upperBound), forKey: key)
    }

    /// A seat amplitude after the ceiling. Linear: the controller's own strength follows the value
    /// linearly (verified on the Steam Controller 2 tester), so a percentage is what the user
    /// expects to feel.
    public static func scaled(_ amplitude: UInt16, percent: Int = loadIntensityPercent()) -> UInt16 {
        guard percent < 100 else { return amplitude }
        guard percent > 0 else { return 0 }
        return UInt16(clamping: Int(amplitude) * percent / 100)
    }
}
