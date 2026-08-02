//  MacForceNow
//
//  Created by OpenAI on 7/6/26.
//

import Foundation

enum MacForceNowInterfacePreferences {
    static let controllerModeEnabledKey = "MacForceNow.Interface.ControllerModeEnabled"
    static let uiScaleKey = "MacForceNow.Interface.UIScale"

    static let defaultUIScale: Double = 1.0
    static let uiScaleRange: ClosedRange<Double> = 0.75...2.0

    static var controllerModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: controllerModeEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: controllerModeEnabledKey) }
    }

    static var uiScale: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: uiScaleKey) as? Double
            return clampedUIScale(stored ?? defaultUIScale)
        }
        set { UserDefaults.standard.set(clampedUIScale(newValue), forKey: uiScaleKey) }
    }

    static func clampedUIScale(_ value: Double) -> Double {
        guard value.isFinite else { return defaultUIScale }
        return min(max(value, uiScaleRange.lowerBound), uiScaleRange.upperBound)
    }
}
