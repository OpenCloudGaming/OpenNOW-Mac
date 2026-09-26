import Foundation
import Testing
@testable import OpenNOW

@MainActor
@Suite struct ControllerMappingOverrideRowTests {
    private func makeProfiles() -> (profiles: [UUID: ControllerMappingProfile], defaults: [ControllerFamily: UUID]) {
        let genericDefault = ControllerMappingProfile(name: "Generic default", family: .generic)
        return ([genericDefault.id: genericDefault], [.generic: genericDefault.id])
    }

    @Test func anActiveOverrideNamesTheGameAndSaysItIsActive() {
        let profiles = makeProfiles()
        let boundProfile = ControllerMappingProfile(name: "Racing", family: .generic)
        var profileMap = profiles.profiles
        profileMap[boundProfile.id] = boundProfile
        let entry = ControllerMappingGameOverrideEntry(
            gameIdentity: "game-100",
            family: .generic,
            gameOverride: ControllerMappingGameOverride(profileID: boundProfile.id)
        )

        let row = SettingsControllerMappingOverride.make(
            entry: entry,
            profilesByID: profileMap,
            defaultProfileIDByFamily: profiles.defaults,
            title: "Racing Game"
        )
        #expect(row.title == "Racing Game")
        #expect(row.subtitle == "Generic Controller · Active in this game")
    }

    @Test func aDisabledOverrideSaysItIsKeptButNotApplied() {
        let profiles = makeProfiles()
        let boundProfile = ControllerMappingProfile(name: "Racing", family: .generic)
        var profileMap = profiles.profiles
        profileMap[boundProfile.id] = boundProfile
        let entry = ControllerMappingGameOverrideEntry(
            gameIdentity: "game-100",
            family: .generic,
            gameOverride: ControllerMappingGameOverride(profileID: boundProfile.id, isEnabled: false)
        )

        let row = SettingsControllerMappingOverride.make(
            entry: entry,
            profilesByID: profileMap,
            defaultProfileIDByFamily: profiles.defaults,
            title: "Racing Game"
        )
        #expect(row.subtitle == "Generic Controller · Disabled — kept, not applied")
    }

    @Test func aMissingProfileSaysWhatItFallsBackTo() {
        let profiles = makeProfiles()
        // A blob synced from another Mac naming a profile this one has never merged.
        let entry = ControllerMappingGameOverrideEntry(
            gameIdentity: "game-100",
            family: .generic,
            gameOverride: ControllerMappingGameOverride(profileID: UUID())
        )

        let row = SettingsControllerMappingOverride.make(
            entry: entry,
            profilesByID: profiles.profiles,
            defaultProfileIDByFamily: profiles.defaults,
            title: "Racing Game"
        )
        #expect(row.isProfileMissing)
        #expect(row.subtitle == "Generic Controller · Profile missing on this Mac — falls back to the \"Generic default\" default")
    }

    @Test func aMissingProfileWithNoTypeDefaultSaysItFallsBackToNoMapping() {
        let entry = ControllerMappingGameOverrideEntry(
            gameIdentity: "game-100",
            family: .dualShock4,
            gameOverride: ControllerMappingGameOverride(profileID: UUID())
        )

        let row = SettingsControllerMappingOverride.make(
            entry: entry,
            profilesByID: [:],
            defaultProfileIDByFamily: [:],
            title: "Racing Game"
        )
        #expect(row.subtitle == "DualShock 4 · Profile missing on this Mac — falls back to no mapping")
    }
}
