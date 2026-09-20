import Foundation
import Testing
@testable import OpenNOW

/// The account surface the menu bar shows: seeding it without a window, and the switch and
/// add-account requests that wait for a window to perform them.
@MainActor @Suite(.serialized) struct MenuBarAccountTests {
    @Test func primeAccountsSeedsOnlyWithoutASource() {
        let model = OPNMenuBarSessionModel()
        let seeded = OPNMenuBarAccount(email: "a@b.c", displayName: "A", membershipTier: "Free", isSignedOut: false, isActive: true)
        model.primeAccounts([seeded])
        #expect(model.accounts == [seeded])
        #expect(model.activeAccount == seeded)

        // A source owns the list once attached, so a later seed must not overwrite the live one.
        let source = StubMenuBarSource()
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "", accounts: [])
        model.attach(source: source)
        model.primeAccounts([OPNMenuBarAccount(email: "c@d.e", displayName: "C", membershipTier: "Ultimate", isSignedOut: false, isActive: true)])
        #expect(model.accounts.isEmpty)
    }

    @Test func accountSwitchWaitsForAWindowAndThenRuns() {
        let model = OPNMenuBarSessionModel()
        let source = StubMenuBarSource()
        let other = OPNMenuBarAccount(email: "b@c.d", displayName: "B", membershipTier: "Free", isSignedOut: false, isActive: false)
        let active = OPNMenuBarAccount(email: "a@b.c", displayName: "A", membershipTier: "Free", isSignedOut: false, isActive: true)

        // No window: the request is parked rather than dropped.
        model.requestAccountSwitch(other)
        #expect(source.switchedAccounts.isEmpty)

        // The next window to attach acts on it, and switching to the account already active is a
        // no-op rather than a redundant round trip through auth.
        model.attach(source: source)
        #expect(source.switchedAccounts == [other])
        model.requestAccountSwitch(active)
        #expect(source.switchedAccounts == [other])
    }

    @Test func addAccountWaitsForAWindowAndThenRuns() {
        let model = OPNMenuBarSessionModel()
        let source = StubMenuBarSource()
        model.requestAddAccount()
        #expect(source.addAccountRequests == 0)

        model.attach(source: source)
        #expect(source.addAccountRequests == 1)
    }
}

/// What the catalog hands the menu bar for the account card: the saved accounts, the active mark,
/// and the switch that resolves back to the catalog's own account action.
@MainActor @Suite(.serialized) struct MenuBarCatalogAccountTests {
    @Test func snapshotCarriesTheAccountListAndResolvesASwitch() {
        var switched: [String] = []
        var addAccountRequests = 0
        let model = makeCatalogViewModelForTesting(
            onSwitchAccount: { switched.append($0.email) },
            onAddAccount: { addAccountRequests += 1 }
        )
        let other = LoginAccount(email: "other@b.c", displayName: "Other", providerIdpId: "idp", providerName: "p")
        model.updateMenuBarAccounts([model.account, other], signedOutAccountEmails: ["other@b.c"])

        let accounts = model.menuBarSnapshot.accounts
        #expect(accounts.map(\.email) == ["a@b.c", "other@b.c"])
        #expect(accounts.first?.isActive == true)
        #expect(accounts.last?.isSignedOut == true)

        model.switchAccount(OPNMenuBarAccount(email: "other@b.c", displayName: "Other", membershipTier: "Free", isSignedOut: true, isActive: false))
        #expect(switched == ["other@b.c"])
        model.addAccount()
        #expect(addAccountRequests == 1)
    }

    @Test func switchAskedForBeforeTheListLoadsIsHeldUntilItArrives() {
        var switched: [String] = []
        let model = makeCatalogViewModelForTesting(onSwitchAccount: { switched.append($0.email) })
        // The menu bar opens the window and asks for the switch before the view has pushed the list.
        model.switchAccount(OPNMenuBarAccount(email: "other@b.c", displayName: "Other", membershipTier: "Free", isSignedOut: false, isActive: false))
        #expect(switched.isEmpty)

        let other = LoginAccount(email: "other@b.c", displayName: "Other", providerIdpId: "idp", providerName: "p")
        model.updateMenuBarAccounts([model.account, other], signedOutAccountEmails: [])
        #expect(switched == ["other@b.c"])
    }
}
