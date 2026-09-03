import Foundation

enum OpenNOWInterfacePreferences {
    static let controllerModeEnabledKey = "OpenNOW.Interface.ControllerModeEnabled"
    static let uiScaleKey = "OpenNOW.Interface.UIScale"

    static let defaultUIScale: Double = 1.0
    static let uiScaleRange: ClosedRange<Double> = 0.75...2.0

    static var controllerModeEnabled: Bool {
        get { OPNAppPreferenceStorage.standard.bool(forKey: controllerModeEnabledKey) }
        set { OPNAppPreferenceStorage.standard.set(newValue, forKey: controllerModeEnabledKey) }
    }

    static var uiScale: Double {
        get {
            let stored = OPNAppPreferenceStorage.standard.object(forKey: uiScaleKey) as? Double
            return clampedUIScale(stored ?? defaultUIScale)
        }
        set { OPNAppPreferenceStorage.standard.set(clampedUIScale(newValue), forKey: uiScaleKey) }
    }

    static func clampedUIScale(_ value: Double) -> Double {
        guard value.isFinite else { return defaultUIScale }
        return min(max(value, uiScaleRange.lowerBound), uiScaleRange.upperBound)
    }
}
