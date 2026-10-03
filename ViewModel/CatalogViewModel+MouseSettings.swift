import Foundation

@MainActor
extension CatalogViewModel {
    func setMouseSensitivityPercent(_ value: Double) {
        OPNStreamPreferences.saveMouseSensitivityPercent(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setDirectMouseInputEnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveDirectMouseInputEnabled(enabled)
        loadSettingsPreferences()
    }

    func setRawMouseInputEnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveRawMouseInputEnabled(enabled)
        loadSettingsPreferences()
    }

    func setRawMouseMatchesMacPointerSpeed(_ enabled: Bool) {
        OPNStreamPreferences.saveRawMouseMatchesMacPointerSpeed(enabled)
        loadSettingsPreferences()
    }

    func setCursorPolicyIndex(_ index: Int) {
        OPNStreamPreferences.saveCursorPolicyIndex(index)
        loadSettingsPreferences()
    }

    func setAntiAFKMouseMovementEnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveAntiAFKMouseMovementEnabled(enabled)
        actionMessage = enabled ? "Anti-AFK mouse movement enabled." : "Anti-AFK mouse movement disabled."
        loadSettingsPreferences()
    }
}
