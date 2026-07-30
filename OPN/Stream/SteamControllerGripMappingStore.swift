import Combine
import Foundation

@MainActor
public final class SteamControllerGripMappingStore: ObservableObject {
    public static let shared = SteamControllerGripMappingStore()

    public static let profilesKey = "MacForceNow.Input.SteamControllerGripProfiles"
    public static let activeProfileKey = "MacForceNow.Input.SteamControllerGripActiveProfile"

    @Published public private(set) var profiles: [SteamControllerGripProfile]
    @Published public private(set) var activeProfileID: UUID?
    public private(set) var activeCombos: [SteamControllerGripButton: SteamControllerGripCombo] = [:]

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([SteamControllerGripProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = []
        }
        if let rawID = defaults.string(forKey: Self.activeProfileKey), let id = UUID(uuidString: rawID) {
            activeProfileID = profiles.contains(where: { $0.id == id }) ? id : nil
        } else {
            activeProfileID = nil
        }
        refreshActiveCombos()
    }

    public var activeProfile: SteamControllerGripProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first(where: { $0.id == activeProfileID })
    }

    public func setActiveProfile(_ id: UUID?) {
        activeProfileID = profiles.contains(where: { $0.id == id }) ? id : nil
        persist()
        refreshActiveCombos()
    }

    @discardableResult
    public func createProfile(named name: String) -> SteamControllerGripProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = SteamControllerGripProfile(name: trimmed.isEmpty ? defaultProfileName() : trimmed)
        profiles.append(profile)
        activeProfileID = profile.id
        persist()
        refreshActiveCombos()
        return profile
    }

    public func updateProfile(_ profile: SteamControllerGripProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profile
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.name = trimmed.isEmpty ? profiles[index].name : trimmed
        updated.combos = profile.combos.filter { !$0.value.isEmpty }
        profiles[index] = updated
        persist()
        refreshActiveCombos()
    }

    public func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            activeProfileID = nil
        }
        persist()
        refreshActiveCombos()
    }

    private func defaultProfileName() -> String {
        let base = "Profile"
        var suffix = profiles.count + 1
        var candidate = "\(base) \(suffix)"
        while profiles.contains(where: { $0.name == candidate }) {
            suffix += 1
            candidate = "\(base) \(suffix)"
        }
        return candidate
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.profilesKey)
        }
        if let activeProfileID {
            defaults.set(activeProfileID.uuidString, forKey: Self.activeProfileKey)
        } else {
            defaults.removeObject(forKey: Self.activeProfileKey)
        }
    }

    private func refreshActiveCombos() {
        activeCombos = activeProfile?.combos ?? [:]
    }
}
