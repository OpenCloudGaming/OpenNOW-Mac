import Combine
import Foundation

@MainActor
public final class ControllerMappingStore: ObservableObject {
    public static let shared = ControllerMappingStore()

    nonisolated public static let profilesKey = "OpenNOW.Input.ControllerMappingProfiles"
    /// One default profile per controller type. Supersedes the single steam-only key below.
    nonisolated public static let defaultProfilesKey = "OpenNOW.Input.ControllerMappingActiveProfileByFamily"
    /// `catalogIdentity → family → {profileID, enabled}`. Machine-independent by construction.
    nonisolated public static let gameOverridesKey = "OpenNOW.Input.ControllerMappingGameOverrides"
    /// `appId → catalogIdentity`, so a resumed session can name the game it is streaming.
    nonisolated public static let appIdIdentityIndexKey = "OpenNOW.Input.ControllerMappingAppIdIndex"
    /// Superseded: the single steam-only default. Read only while `defaultProfilesKey` is absent.
    nonisolated public static let legacyActiveProfileKey = "OpenNOW.Input.SteamControllerMappingActiveProfile"

    @Published public private(set) var profiles: [ControllerMappingProfile]
    @Published public private(set) var defaultProfileIDs: [ControllerFamily: UUID]
    @Published public private(set) var gameOverrides: ControllerMappingGameOverrides
    /// The game-level identity of the session being streamed, `nil` outside one. It is what makes
    /// resolution per-game: setting it bumps `revision`, and the monitor's existing subscription
    /// re-resolves every pad within one refresh cycle.
    @Published public private(set) var currentGameIdentity: String?

    private var appIdIdentities: [String: String]
    private var currentAppID: String?

    @Published private var revision = 0
    private let defaults: UserDefaults

    var revisionPublisher: AnyPublisher<Int, Never> { $revision.eraseToAnyPublisher() }

    // MARK: - Resolution

    /// Decision 1's chain for a pad of `family`: an enabled override for the running game, else the
    /// family's default, else `nil` (which every caller renders as the blank passthrough `Default`).
    /// An override naming a profile that is absent locally — deleted here, or not yet merged from
    /// another Mac — is treated as no override and falls through.
    func profile(for family: ControllerFamily) -> ControllerMappingProfile? {
        if let override = activeOverride(for: family), let profile = profile(id: override.profileID, family: family) {
            return profile
        }
        guard let id = defaultProfileIDs[family] else { return nil }
        return profile(id: id, family: family)
    }

    /// The enabled, locally-resolvable override for the running game and family, if any.
    func activeOverride(for family: ControllerFamily) -> ControllerMappingGameOverride? {
        guard let currentGameIdentity,
              let override = gameOverrides.override(for: currentGameIdentity, family: family),
              override.enabled,
              profile(id: override.profileID, family: family) != nil else { return nil }
        return override
    }

    /// Any stored override for the running game and family, including a disabled one — what the
    /// "Remove for this game" affordance keys its enabled state on.
    func storedOverride(for family: ControllerFamily) -> ControllerMappingGameOverride? {
        guard let currentGameIdentity else { return nil }
        return gameOverrides.override(for: currentGameIdentity, family: family)
    }

    func defaultProfileID(for family: ControllerFamily) -> UUID? { defaultProfileIDs[family] }

    var hasCurrentGame: Bool { currentGameIdentity != nil }

    private func profile(id: UUID, family: ControllerFamily) -> ControllerMappingProfile? {
        profiles.first { $0.id == id && $0.family == family }
    }

    /// The steam-type default. Remote Co-Op guests deliberately keep using this global profile
    /// rather than the host's per-game one, so it stays concrete rather than per-game.
    public var activeProfile: ControllerMappingProfile? {
        guard let id = defaultProfileIDs[.steam] else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Kept for the steam-type default, so callers that only ever meant "the Steam default" read
    /// the same thing they always did.
    public var activeProfileID: UUID? { defaultProfileIDs[.steam] }

    // MARK: - Hardware gating

    /// The IMU costs battery, so motion reporting follows every saved profile rather than the one
    /// in effect: a per-game override is still one of the saved profiles.
    var wantsGyroMotion: Bool {
        profiles.contains { $0.family == .steam && $0.gyro.needsMotionReporting }
    }

    /// Raw trackpad capture has to be seized before any profile is known to want it, so it also
    /// spans every saved profile rather than only the resolved ones.
    var requiresRawSteamTrackpads: Bool {
        profiles.contains { $0.family == .steam && $0.wantsRawTrackpadCapture }
    }

    // MARK: - Defaults

    /// Binds a profile as `family`'s default, or clears it when `id` is `nil` or names another
    /// family's profile.
    func setDefaultProfile(_ id: UUID?, for family: ControllerFamily) {
        defaultProfileIDs[family] = id.flatMap { profile(id: $0, family: family)?.id }
        persist()
    }

    // MARK: - Per-game overrides

    /// Binds the profile being edited to the running game for that controller type.
    func setGameOverride(profileID: UUID, for family: ControllerFamily, enabled: Bool = true) {
        guard let currentGameIdentity, let profile = profile(id: profileID, family: family) else { return }
        gameOverrides.set(ControllerMappingGameOverride(profileID: profile.id, enabled: enabled), for: currentGameIdentity, family: family)
        recordIdentityIndex()
        persist()
    }

    func setGameOverrideEnabled(_ enabled: Bool, for family: ControllerFamily) {
        guard let currentGameIdentity, let override = gameOverrides.override(for: currentGameIdentity, family: family) else { return }
        var updated = override
        updated.enabled = enabled
        gameOverrides.set(updated, for: currentGameIdentity, family: family)
        persist()
    }

    func removeGameOverride(for family: ControllerFamily) {
        guard let currentGameIdentity else { return }
        gameOverrides.set(nil, for: currentGameIdentity, family: family)
        persist()
    }

    /// Settings-list mutations, addressed by identity because the running game is not involved.
    func setOverrideEnabled(_ enabled: Bool, catalogIdentity: String, family: ControllerFamily) {
        guard let override = gameOverrides.override(for: catalogIdentity, family: family) else { return }
        var updated = override
        updated.enabled = enabled
        gameOverrides.set(updated, for: catalogIdentity, family: family)
        persist()
    }

    func removeOverride(catalogIdentity: String, family: ControllerFamily) {
        gameOverrides.set(nil, for: catalogIdentity, family: family)
        persist()
    }

    // MARK: - Session

    /// Called when a stream session starts or is resumed. `catalogIdentity` is known on a fresh
    /// launch and on a catalog-resolved resume; otherwise the persisted index is consulted, which
    /// is what keeps a resumed session resolving the same override as a fresh launch.
    func beginSession(appId: String, catalogIdentity: String?) {
        let trimmedAppId = appId.trimmingCharacters(in: .whitespacesAndNewlines)
        currentAppID = trimmedAppId.isEmpty ? nil : trimmedAppId
        let previousIdentity = currentGameIdentity
        let identity = catalogIdentity?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let identity, !identity.isEmpty {
            currentGameIdentity = identity
        } else if let currentAppID {
            currentGameIdentity = appIdIdentities[currentAppID]
        } else {
            currentGameIdentity = nil
        }
        let previousIndex = appIdIdentities
        recordIdentityIndex()
        if appIdIdentities != previousIndex {
            persist()
        } else if currentGameIdentity != previousIdentity {
            bumpRevision()
        }
    }

    /// Called when the session ends or its launch is cancelled. The catalog and Settings then
    /// resolve each type's default again.
    func endSession() {
        guard currentGameIdentity != nil || currentAppID != nil else { return }
        currentGameIdentity = nil
        currentAppID = nil
        bumpRevision()
    }

    /// Persists `appId → catalogIdentity` while both are known, so a later resume of this session
    /// (which carries only the app id) can resolve the same game.
    private func recordIdentityIndex() {
        guard let currentAppID, let currentGameIdentity, !currentAppID.isEmpty, !currentGameIdentity.isEmpty else { return }
        guard appIdIdentities[currentAppID] != currentGameIdentity else { return }
        appIdIdentities[currentAppID] = currentGameIdentity
    }

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loadedProfiles: [ControllerMappingProfile]
        if let data = defaults.data(forKey: Self.profilesKey) ?? defaults.data(forKey: "OpenNOW.Input.SteamControllerMappingProfiles"),
           let decoded = try? JSONDecoder().decode([ControllerMappingProfile].self, from: data) {
            loadedProfiles = decoded
        } else {
            loadedProfiles = Self.migrateLegacyProfiles(defaults: defaults)
        }
        profiles = loadedProfiles
        defaultProfileIDs = Self.loadDefaultProfileIDs(defaults: defaults, profiles: loadedProfiles)
        gameOverrides = Self.loadGameOverrides(defaults: defaults)
        appIdIdentities = Self.loadAppIdIdentities(defaults: defaults)
        if defaults.data(forKey: Self.profilesKey) == nil || defaults.data(forKey: Self.defaultProfilesKey) == nil {
            persist()
        }
    }

    /// The persisted per-family defaults, with the steam-only legacy key folded in **only** while
    /// the new key is absent — so clearing the steam default deliberately is not undone by a
    /// relaunch, and a pre-migration user keeps exactly the default they had.
    private static func loadDefaultProfileIDs(defaults: UserDefaults, profiles: [ControllerMappingProfile]) -> [ControllerFamily: UUID] {
        if let data = defaults.data(forKey: defaultProfilesKey),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            return raw.reduce(into: [:]) { result, entry in
                guard let family = ControllerFamily(rawValue: entry.key),
                      let id = UUID(uuidString: entry.value),
                      profiles.contains(where: { $0.id == id && $0.family == family }) else { return }
                result[family] = id
            }
        }
        if let rawID = defaults.string(forKey: legacyActiveProfileKey), let id = UUID(uuidString: rawID),
           profiles.contains(where: { $0.id == id && $0.family == .steam }) {
            return [.steam: id]
        }
        // No stored default at all: keep the pre-feature behaviour of activating the first Steam
        // profile, which is the migrated `Default` on a fresh install.
        guard let firstSteam = profiles.first(where: { $0.family == .steam })?.id else { return [:] }
        return [.steam: firstSteam]
    }

    private static func loadGameOverrides(defaults: UserDefaults) -> ControllerMappingGameOverrides {
        guard let data = defaults.data(forKey: gameOverridesKey),
              let decoded = try? JSONDecoder().decode(ControllerMappingGameOverrides.self, from: data) else {
            return ControllerMappingGameOverrides()
        }
        return decoded
    }

    private static func loadAppIdIdentities(defaults: UserDefaults) -> [String: String] {
        guard let data = defaults.data(forKey: appIdIdentityIndexKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    // MARK: - Profiles

    /// Creating a profile makes it that controller type's default, which is what steam already did
    /// and what decision 5 generalises. The UI states the consequence.
    @discardableResult
    public func createProfile(named name: String, family: ControllerFamily = .steam) -> ControllerMappingProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ControllerMappingProfile(name: trimmed.isEmpty ? defaultProfileName() : trimmed, family: family)
        profiles.append(profile)
        defaultProfileIDs[family] = profile.id
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

    /// Deletes the profile and every reference to it: the family default it may hold and every
    /// per-game override binding it, so no row can be left pointing at a profile that is gone.
    public func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        defaultProfileIDs = defaultProfileIDs.filter { $0.value != id }
        gameOverrides.removeProfile(id)
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

    private func bumpRevision() { revision += 1 }

    private func persist() {
        defer { revision += 1 }
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.profilesKey)
        }
        let rawDefaults = Dictionary(uniqueKeysWithValues: defaultProfileIDs.map { ($0.key.rawValue, $0.value.uuidString) })
        if let data = try? JSONEncoder().encode(rawDefaults) {
            defaults.set(data, forKey: Self.defaultProfilesKey)
        }
        if let data = try? JSONEncoder().encode(gameOverrides) {
            defaults.set(data, forKey: Self.gameOverridesKey)
        }
        if let data = try? JSONEncoder().encode(appIdIdentities) {
            defaults.set(data, forKey: Self.appIdIdentityIndexKey)
        }
        // The superseded steam-only key is never written again; the new key owns the default.
        defaults.removeObject(forKey: Self.legacyActiveProfileKey)
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
