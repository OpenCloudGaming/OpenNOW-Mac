import Combine
import Foundation

@MainActor
public final class ControllerMappingStore: ObservableObject {
    public static let shared = ControllerMappingStore()

    public static let profilesKey = "OpenNOW.Input.ControllerMappingProfiles"
    public static let activeProfileKey = "OpenNOW.Input.SteamControllerMappingActiveProfile"

    @Published public private(set) var profiles: [ControllerMappingProfile]
    @Published public private(set) var activeProfileID: UUID?

    @Published private var revision = 0
    private var assignments: [InputDeviceID: UUID] = [:]
    private let defaults: UserDefaults

    var revisionPublisher: AnyPublisher<Int, Never> { $revision.eraseToAnyPublisher() }

    func profile(for deviceID: InputDeviceID, family: ControllerFamily) -> ControllerMappingProfile? {
        if let id = assignments[deviceID], let profile = profiles.first(where: { $0.id == id && $0.family == family }) {
            return profile
        }
        return family == .steam ? activeProfile : nil
    }

    func assignProfile(_ id: UUID?, to deviceID: InputDeviceID, family: ControllerFamily) {
        assignments[deviceID] = profiles.first(where: { $0.id == id && $0.family == family })?.id
        revision += 1
    }

    func removeDisconnectedAssignments(connectedIDs: Set<InputDeviceID>) {
        let next = assignments.filter { connectedIDs.contains($0.key) }
        guard next != assignments else { return }
        assignments = next
        revision += 1
    }

    var requiresRawSteamTrackpads: Bool {
        activeProfile?.wantsRawTrackpadCapture == true || assignments.values.contains { id in
            profiles.contains { $0.id == id && $0.family == .steam && $0.wantsRawTrackpadCapture }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.profilesKey) ?? defaults.data(forKey: "OpenNOW.Input.SteamControllerMappingProfiles"),
           let decoded = try? JSONDecoder().decode([ControllerMappingProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = Self.migrateLegacyProfiles(defaults: defaults)
        }
        if let rawID = defaults.string(forKey: Self.activeProfileKey), let id = UUID(uuidString: rawID) {
            activeProfileID = profiles.contains(where: { $0.id == id && $0.family == .steam }) ? id : nil
        } else {
            activeProfileID = profiles.first(where: { $0.family == .steam })?.id
        }
        if defaults.data(forKey: Self.profilesKey) == nil {
            persist()
        }
    }

    public var activeProfile: ControllerMappingProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first(where: { $0.id == activeProfileID })
    }

    public func setActiveProfile(_ id: UUID?) {
        activeProfileID = profiles.contains(where: { $0.id == id && $0.family == .steam }) ? id : nil
        persist()
    }

    @discardableResult
    public func createProfile(named name: String, family: ControllerFamily = .steam, activateSteamDefault: Bool = true) -> ControllerMappingProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ControllerMappingProfile(name: trimmed.isEmpty ? defaultProfileName() : trimmed, family: family)
        profiles.append(profile)
        if family == .steam, activateSteamDefault { activeProfileID = profile.id }
        persist()
        return profile
    }

    public func updateProfile(_ profile: ControllerMappingProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profile
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.name = trimmed.isEmpty ? profiles[index].name : trimmed
        profiles[index] = updated
        persist()
    }

    public func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
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
        defer { revision += 1 }
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
    private static let legacyGripProfilesKey = "OpenNOW.Input.SteamControllerGripProfiles"
    private static let legacyGripActiveProfileKey = "OpenNOW.Input.SteamControllerGripActiveProfile"

    /// First launch after this feature ships: fold the old grip-only profile (if any)
    /// and the old global trackpad-mouse toggle into one migrated profile, so existing
    /// users see identical behavior until they open the new editor.
    private static func migrateLegacyProfiles(defaults: UserDefaults) -> [ControllerMappingProfile] {
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
        let migrated = ControllerMappingProfile.migratedDefault(legacyGrips: legacyGrips, legacyTrackpadMouseEnabled: legacyTrackpadMouseEnabled)
        return [migrated]
    }
}
