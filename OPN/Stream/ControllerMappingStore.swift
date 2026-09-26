import Combine
import Foundation

@MainActor
public final class ControllerMappingStore: ObservableObject {
    public static let shared = ControllerMappingStore()

    nonisolated public static let profilesKey = "OpenNOW.Input.ControllerMappingProfiles"
    nonisolated public static let familyDefaultsKey = "OpenNOW.Input.ControllerMappingActiveProfileByFamily"
    nonisolated public static let gameOverridesKey = "OpenNOW.Input.ControllerMappingGameOverrides"
    nonisolated public static let appIdIdentityIndexKey = "OpenNOW.Input.ControllerMappingAppIdIndex"
    nonisolated public static let legacySteamDefaultKey = "OpenNOW.Input.SteamControllerMappingActiveProfile"

    @Published public private(set) var profiles: [ControllerMappingProfile]
    @Published public private(set) var defaultProfileIDs: [ControllerFamily: UUID]
    @Published public private(set) var gameOverrides: ControllerMappingGameOverrides
    /// The running session's game identity, `nil` outside one. Setting it bumps `revision`, which
    /// is what re-resolves every pad within one refresh cycle.
    @Published public private(set) var currentGameIdentity: String?

    private var gameIdentityByAppId: [String: String]
    private var currentAppId: String?

    @Published private var revision = 0
    private let defaults: UserDefaults

    var revisionPublisher: AnyPublisher<Int, Never> { $revision.eraseToAnyPublisher() }

    // MARK: - Resolution

    /// Enabled override for the running game, else the family default, else `nil` for passthrough.
    /// An override naming a profile absent locally falls through instead of failing.
    func profile(for family: ControllerFamily) -> ControllerMappingProfile? {
        if let override = activeOverride(for: family), let overrideProfile = profile(id: override.profileID, family: family) {
            return overrideProfile
        }
        guard let defaultProfileID = defaultProfileIDs[family] else { return nil }
        return profile(id: defaultProfileID, family: family)
    }

    /// The enabled, locally-resolvable override for the running game and family, if any.
    func activeOverride(for family: ControllerFamily) -> ControllerMappingGameOverride? {
        guard let currentGameIdentity,
              let gameOverride = gameOverrides.override(forGameIdentity: currentGameIdentity, family: family),
              gameOverride.isEnabled,
              profile(id: gameOverride.profileID, family: family) != nil else { return nil }
        return gameOverride
    }

    /// Any stored override for the running game and family, including a disabled one.
    func storedOverride(for family: ControllerFamily) -> ControllerMappingGameOverride? {
        guard let currentGameIdentity else { return nil }
        return gameOverrides.override(forGameIdentity: currentGameIdentity, family: family)
    }

    func defaultProfileID(for family: ControllerFamily) -> UUID? { defaultProfileIDs[family] }

    var isCurrentGameKnown: Bool { currentGameIdentity != nil }

    private func profile(id: UUID, family: ControllerFamily) -> ControllerMappingProfile? {
        profiles.first { $0.id == id && $0.family == family }
    }

    /// The steam-type default. Remote Co-Op guests deliberately keep using this global profile.
    public var activeProfile: ControllerMappingProfile? {
        guard let defaultProfileID = defaultProfileIDs[.steam] else { return nil }
        return profiles.first { $0.id == defaultProfileID }
    }

    // MARK: - Hardware gating

    /// The IMU costs battery, so motion reporting spans every saved profile, not only the resolved one.
    var wantsGyroMotion: Bool {
        profiles.contains { $0.family == .steam && $0.gyro.needsMotionReporting }
    }

    /// Raw trackpad capture is seized before any profile is known to want it, so it too spans all.
    var requiresRawSteamTrackpads: Bool {
        profiles.contains { $0.family == .steam && $0.wantsRawTrackpadCapture }
    }

    // MARK: - Defaults

    /// Binds `id` as `family`'s default, or clears it when `id` is `nil` or another family's profile.
    func setDefaultProfile(_ id: UUID?, for family: ControllerFamily) {
        let resolvedProfileID = id.flatMap { profile(id: $0, family: family)?.id }
        defaultProfileIDs[family] = resolvedProfileID
        persist()
    }

    // MARK: - Per-game overrides

    /// Binds the profile being edited to the running game for that controller type, enabled.
    func setGameOverride(profileID: UUID, for family: ControllerFamily) {
        guard let currentGameIdentity, let boundProfile = profile(id: profileID, family: family) else { return }
        let gameOverride = ControllerMappingGameOverride(profileID: boundProfile.id)
        gameOverrides.setOverride(gameOverride, forGameIdentity: currentGameIdentity, family: family)
        recordGameIdentityForCurrentApp()
        persist()
    }

    func setGameOverrideEnabled(_ isEnabled: Bool, for family: ControllerFamily) {
        guard let currentGameIdentity,
              let storedGameOverride = gameOverrides.override(forGameIdentity: currentGameIdentity, family: family) else { return }
        var updatedGameOverride = storedGameOverride
        updatedGameOverride.isEnabled = isEnabled
        gameOverrides.setOverride(updatedGameOverride, forGameIdentity: currentGameIdentity, family: family)
        persist()
    }

    func removeGameOverride(for family: ControllerFamily) {
        guard let currentGameIdentity else { return }
        gameOverrides.setOverride(nil, forGameIdentity: currentGameIdentity, family: family)
        persist()
    }

    /// Settings-list mutations, addressed by game identity because no session is involved.
    func setOverrideEnabled(_ isEnabled: Bool, gameIdentity: String, family: ControllerFamily) {
        guard let storedGameOverride = gameOverrides.override(forGameIdentity: gameIdentity, family: family) else { return }
        var updatedGameOverride = storedGameOverride
        updatedGameOverride.isEnabled = isEnabled
        gameOverrides.setOverride(updatedGameOverride, forGameIdentity: gameIdentity, family: family)
        persist()
    }

    func removeOverride(gameIdentity: String, family: ControllerFamily) {
        gameOverrides.setOverride(nil, forGameIdentity: gameIdentity, family: family)
        persist()
    }

    // MARK: - Session

    /// Starts or resumes a session. The identity is known on a fresh launch, or read back from the
    /// index a previous launch wrote, so a resume resolves the same override as a fresh launch.
    func beginSession(appId: String, catalogIdentity: String?) {
        let trimmedAppId = appId.trimmingCharacters(in: .whitespacesAndNewlines)
        currentAppId = trimmedAppId.isEmpty ? nil : trimmedAppId
        let previousGameIdentity = currentGameIdentity
        currentGameIdentity = resolveGameIdentity(catalogIdentity: catalogIdentity)
        let previousIndex = gameIdentityByAppId
        recordGameIdentityForCurrentApp()
        let didIndexChange = gameIdentityByAppId != previousIndex
        let didGameChange = currentGameIdentity != previousGameIdentity
        guard didIndexChange || didGameChange else { return }
        guard didIndexChange else {
            bumpRevision()
            return
        }
        persist()
    }

    /// Ends the session so the catalog and Settings resolve each type's default again.
    func endSession() {
        guard currentGameIdentity != nil || currentAppId != nil else { return }
        currentGameIdentity = nil
        currentAppId = nil
        bumpRevision()
    }

    private func resolveGameIdentity(catalogIdentity: String?) -> String? {
        let trimmedIdentity = catalogIdentity?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedIdentity, !trimmedIdentity.isEmpty { return trimmedIdentity }
        guard let currentAppId else { return nil }
        return gameIdentityByAppId[currentAppId]
    }

    /// Persists `appId → catalogIdentity` while both are known, for a later resume of this session.
    private func recordGameIdentityForCurrentApp() {
        guard let currentAppId, let currentGameIdentity else { return }
        guard !currentAppId.isEmpty, !currentGameIdentity.isEmpty else { return }
        guard gameIdentityByAppId[currentAppId] != currentGameIdentity else { return }
        gameIdentityByAppId[currentAppId] = currentGameIdentity
    }

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loadedProfiles = Self.loadProfiles(defaults: defaults)
        profiles = loadedProfiles
        defaultProfileIDs = Self.loadDefaultProfileIDs(defaults: defaults, profiles: loadedProfiles)
        gameOverrides = Self.loadGameOverrides(defaults: defaults)
        gameIdentityByAppId = Self.loadGameIdentityByAppId(defaults: defaults)
        let isProfilesKeyMissing = defaults.data(forKey: Self.profilesKey) == nil
        let isFamilyDefaultsKeyMissing = defaults.data(forKey: Self.familyDefaultsKey) == nil
        guard isProfilesKeyMissing || isFamilyDefaultsKeyMissing else { return }
        persist()
    }

    private static func loadProfiles(defaults: UserDefaults) -> [ControllerMappingProfile] {
        let storedData = defaults.data(forKey: profilesKey) ?? defaults.data(forKey: "OpenNOW.Input.SteamControllerMappingProfiles")
        guard let storedData, let decoded = try? JSONDecoder().decode([ControllerMappingProfile].self, from: storedData) else {
            return migrateLegacyProfiles(defaults: defaults)
        }
        return decoded
    }

    /// The persisted family defaults, with the steam-only legacy key folded in only while the new
    /// key is absent, so clearing the Steam default deliberately is not undone by a relaunch.
    private static func loadDefaultProfileIDs(defaults: UserDefaults, profiles: [ControllerMappingProfile]) -> [ControllerFamily: UUID] {
        let storedData = defaults.data(forKey: familyDefaultsKey)
        guard let storedData, let rawDefaults = try? JSONDecoder().decode([String: String].self, from: storedData) else {
            return legacySteamDefaultFallback(defaults: defaults, profiles: profiles)
        }
        return rawDefaults.reduce(into: [:]) { result, entry in
            guard let family = ControllerFamily(rawValue: entry.key) else { return }
            guard let profileID = UUID(uuidString: entry.value) else { return }
            guard profiles.contains(where: { $0.id == profileID && $0.family == family }) else { return }
            result[family] = profileID
        }
    }

    private static func legacySteamDefaultFallback(defaults: UserDefaults, profiles: [ControllerMappingProfile]) -> [ControllerFamily: UUID] {
        if let legacyProfileID = legacySteamDefaultProfileID(defaults: defaults, profiles: profiles) {
            return [.steam: legacyProfileID]
        }
        guard let firstSteamProfileID = profiles.first(where: { $0.family == .steam })?.id else { return [:] }
        return [.steam: firstSteamProfileID]
    }

    private static func legacySteamDefaultProfileID(defaults: UserDefaults, profiles: [ControllerMappingProfile]) -> UUID? {
        guard let rawProfileID = defaults.string(forKey: legacySteamDefaultKey) else { return nil }
        guard let profileID = UUID(uuidString: rawProfileID) else { return nil }
        guard profiles.contains(where: { $0.id == profileID && $0.family == .steam }) else { return nil }
        return profileID
    }

    private static func loadGameOverrides(defaults: UserDefaults) -> ControllerMappingGameOverrides {
        guard let storedData = defaults.data(forKey: gameOverridesKey),
              let decoded = try? JSONDecoder().decode(ControllerMappingGameOverrides.self, from: storedData) else {
            return ControllerMappingGameOverrides()
        }
        return decoded
    }

    private static func loadGameIdentityByAppId(defaults: UserDefaults) -> [String: String] {
        guard let storedData = defaults.data(forKey: appIdIdentityIndexKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: storedData) else { return [:] }
        return decoded
    }

    // MARK: - Profiles

    /// Creating a profile makes it that controller type's default; the sheet states that in the UI.
    @discardableResult
    public func createProfile(named name: String, family: ControllerFamily = .steam) -> ControllerMappingProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let createdProfile = ControllerMappingProfile(name: trimmedName.isEmpty ? defaultProfileName() : trimmedName, family: family)
        profiles.append(createdProfile)
        defaultProfileIDs[family] = createdProfile.id
        persist()
        return createdProfile
    }

    public func updateProfile(_ profile: ControllerMappingProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updatedProfile = profile
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedProfile.name = trimmedName.isEmpty ? profiles[index].name : trimmedName
        profiles[index] = updatedProfile
        persist()
    }

    /// Removes the profile's references too: the family default it may hold and every override.
    public func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        defaultProfileIDs = defaultProfileIDs.filter { $0.value != id }
        gameOverrides.removeOverrides(referencingProfile: id)
        persist()
    }

    private func defaultProfileName() -> String {
        let baseName = "Profile"
        var suffix = profiles.count + 1
        var candidateName = "\(baseName) \(suffix)"
        while profiles.contains(where: { $0.name == candidateName }) {
            suffix += 1
            candidateName = "\(baseName) \(suffix)"
        }
        return candidateName
    }

    private func bumpRevision() { revision += 1 }

    private func persist() {
        defer { revision += 1 }
        write(profiles, toKey: Self.profilesKey)
        write(familyDefaultsByRawValue, toKey: Self.familyDefaultsKey)
        write(gameOverrides, toKey: Self.gameOverridesKey)
        write(gameIdentityByAppId, toKey: Self.appIdIdentityIndexKey)
        // The superseded steam-only key is never written again; the new key owns the default.
        defaults.removeObject(forKey: Self.legacySteamDefaultKey)
    }

    private var familyDefaultsByRawValue: [String: String] {
        defaultProfileIDs.reduce(into: [:]) { result, entry in
            result[entry.key.rawValue] = entry.value.uuidString
        }
    }

    private func write<Value: Encodable>(_ value: Value, toKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    // Superseded store's persistence keys — read once during migration below, then never again.
    private static let legacyGripProfilesKey = "OpenNOW.Input.SteamControllerGripProfiles"
    private static let legacyGripActiveProfileKey = "OpenNOW.Input.SteamControllerGripActiveProfile"

    /// First launch after this feature ships: fold the old grip-only profile (if any) into one
    /// migrated profile, so existing users see identical behaviour until they open the new editor.
    private static func migrateLegacyProfiles(defaults: UserDefaults) -> [ControllerMappingProfile] {
        let legacyGrips = loadLegacyGripProfile(defaults: defaults)
        let trackpadMouseKey = SteamControllerTrackpadMousePreference.key
        let legacyTrackpadMouseEnabled = defaults.object(forKey: trackpadMouseKey) == nil ? true : defaults.bool(forKey: trackpadMouseKey)
        let migratedProfile = ControllerMappingProfile.migratedDefault(legacyGrips: legacyGrips, legacyTrackpadMouseEnabled: legacyTrackpadMouseEnabled)
        return [migratedProfile]
    }

    private static func loadLegacyGripProfile(defaults: UserDefaults) -> SteamControllerGripProfile? {
        guard let storedData = defaults.data(forKey: legacyGripProfilesKey) else { return nil }
        guard let decodedGrips = try? JSONDecoder().decode([SteamControllerGripProfile].self, from: storedData) else { return nil }
        guard let rawProfileID = defaults.string(forKey: legacyGripActiveProfileKey) else { return decodedGrips.first }
        guard let profileID = UUID(uuidString: rawProfileID) else { return decodedGrips.first }
        return decodedGrips.first { $0.id == profileID }
    }
}
