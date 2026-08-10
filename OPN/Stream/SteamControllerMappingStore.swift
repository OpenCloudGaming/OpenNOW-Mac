import Combine
import Foundation

@MainActor
public final class SteamControllerMappingStore: ObservableObject {
    public static let shared = SteamControllerMappingStore()

    public static let profilesKey = "MacForceNow.Input.SteamControllerMappingProfiles"
    public static let activeProfileKey = "MacForceNow.Input.SteamControllerMappingActiveProfile"

    @Published public private(set) var profiles: [SteamControllerMappingProfile]
    @Published public private(set) var activeProfileID: UUID?

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([SteamControllerMappingProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = Self.migrateLegacyProfiles(defaults: defaults)
        }
        if let rawID = defaults.string(forKey: Self.activeProfileKey), let id = UUID(uuidString: rawID) {
            activeProfileID = profiles.contains(where: { $0.id == id }) ? id : nil
        } else {
            activeProfileID = profiles.first?.id
        }
        if defaults.data(forKey: Self.profilesKey) == nil {
            persist()
        }
    }

    public var activeProfile: SteamControllerMappingProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first(where: { $0.id == activeProfileID })
    }

    public func setActiveProfile(_ id: UUID?) {
        activeProfileID = profiles.contains(where: { $0.id == id }) ? id : nil
        persist()
    }

    @discardableResult
    public func createProfile(named name: String) -> SteamControllerMappingProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = SteamControllerMappingProfile(name: trimmed.isEmpty ? defaultProfileName() : trimmed)
        profiles.append(profile)
        activeProfileID = profile.id
        persist()
        return profile
    }

    public func updateProfile(_ profile: SteamControllerMappingProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profile
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.name = trimmed.isEmpty ? profiles[index].name : trimmed
        profiles[index] = updated
        persist()
    }

    public func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            activeProfileID = nil
        }
        persist()
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

    // Superseded store's persistence keys — read once during migration below, then never again.
    private static let legacyGripProfilesKey = "MacForceNow.Input.SteamControllerGripProfiles"
    private static let legacyGripActiveProfileKey = "MacForceNow.Input.SteamControllerGripActiveProfile"

    /// First launch after this feature ships: fold the old grip-only profile (if any)
    /// and the old global trackpad-mouse toggle into one migrated profile, so existing
    /// users see identical behavior until they open the new editor.
    private static func migrateLegacyProfiles(defaults: UserDefaults) -> [SteamControllerMappingProfile] {
        var legacyGrips: SteamControllerGripProfile?
        if let data = defaults.data(forKey: Self.legacyGripProfilesKey),
           let decoded = try? JSONDecoder().decode([SteamControllerGripProfile].self, from: data) {
            if let rawID = defaults.string(forKey: Self.legacyGripActiveProfileKey), let id = UUID(uuidString: rawID) {
                legacyGrips = decoded.first(where: { $0.id == id })
            } else {
                legacyGrips = decoded.first
            }
        }
        let key = SteamControllerTrackpadMousePreference.key
        let legacyTrackpadMouseEnabled = defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
        let migrated = SteamControllerMappingProfile.migratedDefault(legacyGrips: legacyGrips, legacyTrackpadMouseEnabled: legacyTrackpadMouseEnabled)
        return [migrated]
    }
}
