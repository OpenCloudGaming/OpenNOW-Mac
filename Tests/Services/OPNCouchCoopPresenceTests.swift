import Foundation
import Testing
@testable import OpenNOW

private let bundle = OPNProductIdentity.releaseBundleIdentifier

@Suite("OPNCouchCoopPresence")
struct OPNCouchCoopPresenceTests {
    @Test func coOpIsActiveOnlyWithTheFlagAndASecondProcess() {
        #expect(OPNCouchCoopPresence.isActive(isFlagEnabled: true, livingProcessIdentifiers: [10, 11]))
        #expect(!OPNCouchCoopPresence.isActive(isFlagEnabled: true, livingProcessIdentifiers: [10]))
        #expect(!OPNCouchCoopPresence.isActive(isFlagEnabled: true, livingProcessIdentifiers: []))
        #expect(!OPNCouchCoopPresence.isActive(isFlagEnabled: false, livingProcessIdentifiers: [10, 11]))
    }

    @Test func updateInstallsAreBlockedOnlyWhileCoOpIsActive() {
        #expect(OPNCouchCoopPresence.blocksUpdateInstall(isFlagEnabled: true, isActive: true))
        #expect(!OPNCouchCoopPresence.blocksUpdateInstall(isFlagEnabled: true, isActive: false))
        #expect(!OPNCouchCoopPresence.blocksUpdateInstall(isFlagEnabled: false, isActive: true))
    }

    @Test func theAnnouncementNameFollowsTheBundleIdentifier() {
        #expect(OPNCouchCoopPresence.announcementName(bundleIdentifier: bundle).rawValue == "\(bundle).couchCoop.presence")
        #expect(OPNCouchCoopPresence.announcementName(bundleIdentifier: "\(bundle).dev") != OPNCouchCoopPresence.announcementName(bundleIdentifier: bundle))
    }

    @Test func anAnnouncementSurvivesItsUserInfo() {
        let announcement = OPNCouchCoopAnnouncement(instanceNumber: 2, processIdentifier: 4_242, screenIdentifier: 69_733_248, assignmentRevision: 3)
        #expect(OPNCouchCoopAnnouncement(userInfo: announcement.userInfo) == announcement)
    }

    @Test func anAnnouncementCarriesItsAssignmentOverrides() {
        let overrides: [String: OPNCouchCoopPadTarget] = ["Xbox#0": .instance(2), "steam-controller-9": .off]
        let announcement = OPNCouchCoopAnnouncement(instanceNumber: 1, processIdentifier: 7, screenIdentifier: nil, assignmentRevision: 4, assignmentOverrides: overrides)
        #expect(OPNCouchCoopAnnouncement(userInfo: announcement.userInfo)?.assignmentOverrides == overrides)
    }

    @Test func anAnnouncementWithoutOverridesOmitsTheKey() {
        let announcement = OPNCouchCoopAnnouncement(instanceNumber: 1, processIdentifier: 7, screenIdentifier: nil, assignmentRevision: 0)
        #expect(announcement.userInfo[OPNCouchCoopAnnouncement.assignmentsKey] == nil)
    }

    @Test func theAssignmentRequestNameFollowsTheBundleIdentifier() {
        #expect(OPNCouchCoopPresence.assignmentRequestName(bundleIdentifier: bundle).rawValue == "\(bundle).couchCoop.assignmentRequest")
    }

    @Test func anAnnouncementWithoutAScreenKeepsItNil() {
        let announcement = OPNCouchCoopAnnouncement(instanceNumber: 1, processIdentifier: 7, screenIdentifier: nil, assignmentRevision: 0)
        #expect(announcement.userInfo[OPNCouchCoopAnnouncement.screenKey] == nil)
        #expect(OPNCouchCoopAnnouncement(userInfo: announcement.userInfo)?.screenIdentifier == nil)
    }

    @Test func aMalformedAnnouncementIsRejected() {
        #expect(OPNCouchCoopAnnouncement(userInfo: nil) == nil)
        #expect(OPNCouchCoopAnnouncement(userInfo: [:]) == nil)
        #expect(OPNCouchCoopAnnouncement(userInfo: ["instance": 0, "pid": 5, "revision": 0]) == nil)
        #expect(OPNCouchCoopAnnouncement(userInfo: ["instance": "two", "pid": 5, "revision": 0]) == nil)
        #expect(OPNCouchCoopAnnouncement(userInfo: ["instance": 2, "pid": 5]) == nil)
    }

    @Test func theRosterReportsANewProcessOnceAndKeepsTheNewestRevision() {
        var roster = OPNCouchCoopRoster()
        let first = OPNCouchCoopAnnouncement(instanceNumber: 2, processIdentifier: 20, screenIdentifier: 1, assignmentRevision: 1)
        let newer = OPNCouchCoopAnnouncement(instanceNumber: 2, processIdentifier: 20, screenIdentifier: 2, assignmentRevision: 2)
        let stale = OPNCouchCoopAnnouncement(instanceNumber: 2, processIdentifier: 20, screenIdentifier: 3, assignmentRevision: 1)

        #expect(roster.record(first))
        #expect(!roster.record(newer))
        #expect(!roster.record(stale))
        #expect(roster.announcement(forInstance: 2) == newer)
    }

    @Test func aRestartedInstanceReplacesItsOldProcess() {
        var roster = OPNCouchCoopRoster()
        roster.record(OPNCouchCoopAnnouncement(instanceNumber: 2, processIdentifier: 20, screenIdentifier: nil, assignmentRevision: 5))
        let restarted = OPNCouchCoopAnnouncement(instanceNumber: 2, processIdentifier: 21, screenIdentifier: nil, assignmentRevision: 0)

        #expect(roster.record(restarted))
        #expect(roster.announcement(forInstance: 2)?.processIdentifier == 21)
    }

    @Test func pruningDropsInstancesWhoseProcessIsGone() {
        var roster = OPNCouchCoopRoster()
        roster.record(OPNCouchCoopAnnouncement(instanceNumber: 1, processIdentifier: 10, screenIdentifier: nil, assignmentRevision: 0))
        roster.record(OPNCouchCoopAnnouncement(instanceNumber: 2, processIdentifier: 20, screenIdentifier: nil, assignmentRevision: 0))

        roster.prune(livingProcessIdentifiers: [10])

        #expect(roster.instanceNumbers == [1])
    }

    @Test func theRosterListsInstancesInOrder() {
        var roster = OPNCouchCoopRoster()
        roster.record(OPNCouchCoopAnnouncement(instanceNumber: 2, processIdentifier: 20, screenIdentifier: nil, assignmentRevision: 0))
        roster.record(OPNCouchCoopAnnouncement(instanceNumber: 1, processIdentifier: 10, screenIdentifier: nil, assignmentRevision: 0))
        #expect(roster.instanceNumbers == [1, 2])
    }
}

@Suite("OPNCouchCoopLauncher")
@MainActor
struct OPNCouchCoopLauncherTests {
    @Test func theSecondCopyIsStartedWithItsInstanceAndWithoutRestoredState() {
        #expect(OPNCouchCoopLauncher.launchArguments(instanceNumber: 2) == ["--opn-instance", "2", "-ApplePersistenceIgnoreState", "YES"])
    }

    @Test func launchArgumentsResolveBackToTheInstanceTheyName() {
        let arguments = ["OpenNOW"] + OPNCouchCoopLauncher.launchArguments(instanceNumber: 2)
        #expect(OPNAppInstance.requestedNumber(arguments: arguments) == 2)
    }

    @Test func theNextInstanceIsTheLowestFreeSecondaryNumber() {
        #expect(OPNCouchCoopLauncher.nextInstanceNumber(occupied: [1]) == 2)
        #expect(OPNCouchCoopLauncher.nextInstanceNumber(occupied: []) == 2)
        #expect(OPNCouchCoopLauncher.nextInstanceNumber(occupied: [1, 2]) == nil)
    }

    @Test func startingNeedsTheFlagAndAFreeSlot() {
        #expect(OPNCouchCoopLauncher.canStart(isFlagEnabled: true, occupied: [1]))
        #expect(!OPNCouchCoopLauncher.canStart(isFlagEnabled: false, occupied: [1]))
        #expect(!OPNCouchCoopLauncher.canStart(isFlagEnabled: true, occupied: [1, 2]))
    }
}

@Suite("OPNCouchCoopLabels")
struct OPNCouchCoopLabelsTests {
    private let primary = OPNAppInstance(number: 1, bundleIdentifier: bundle)
    private let secondary = OPNAppInstance(number: 2, bundleIdentifier: bundle)

    @Test func theFirstCopyIsUnlabeledUntilCoOpIsRunning() {
        #expect(OPNCouchCoopLabels.windowTitle(base: "OpenNOW", instance: primary, isCouchCoopActive: false) == "OpenNOW")
        #expect(OPNCouchCoopLabels.dockMark(instance: primary, isCouchCoopActive: false) == nil)
        #expect(OPNCouchCoopLabels.windowTitle(base: "OpenNOW", instance: primary, isCouchCoopActive: true) == "OpenNOW \u{00B7} Player 1")
        #expect(OPNCouchCoopLabels.dockMark(instance: primary, isCouchCoopActive: true) == "P1")
    }

    @Test func aSecondaryCopyIsAlwaysLabeled() {
        #expect(OPNCouchCoopLabels.windowTitle(base: "Portal 2", instance: secondary, isCouchCoopActive: false) == "Portal 2 \u{00B7} Player 2")
        #expect(OPNCouchCoopLabels.dockMark(instance: secondary, isCouchCoopActive: false) == "P2")
        #expect(OPNCouchCoopLabels.playerName(instance: secondary) == "Player 2")
    }
}
