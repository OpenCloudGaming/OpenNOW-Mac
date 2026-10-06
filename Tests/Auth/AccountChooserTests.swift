//  The saved-account chooser: the startup gate, "Switch account…", and the promise that cancelling
//  picks nothing. One serialized suite, because these tests share the stored startup preference.

import Foundation
import SwiftData
import Testing
@testable import OpenNOW

private final class NoopLoginAuthService: LoginAuthServing, @unchecked Sendable {
    func invalidatePendingAuthentication() {}

    func startOAuthLogin(providerIdpId: String, completion: @escaping OPNAuthCallback) {
        Task { @MainActor in completion(false, OPNAuthSession(), "Unused by this test") }
    }

    func startStarfleetDeviceCodeLogin(providerIdpId: String, challengeHandler: @escaping OPNDeviceCodeChallengeCallback, completion: @escaping OPNAuthCallback) {
        Task { @MainActor in completion(false, OPNAuthSession(), "Unused by this test") }
    }

    func endSavedSession(userId: String, email: String) {}
}

/// Answers provider discovery without a network round trip, so a test that walks into the sign-in
/// path does not also make a request.
private final class StubProviderInfoService: GameProviderInfoServing, @unchecked Sendable {
    func fetchProviderInfo(idpId: String, completion: @escaping OPNProviderInfoCallback) {
        Task { @MainActor in completion(false, OPNGameProviderInfo(), OPNGameProviderEndpoint(), "Unused by this test") }
    }
}

@MainActor
private final class ChooserFixture {
    let container: ModelContainer
    let viewModel: LoginViewModel
    let registry = OPNGameSessionRegistry()
    let accountA: LoginAccount
    let accountB: LoginAccount
    let sessionA: LoginSession
    let sessionB: LoginSession

    /// `secondAccountUsable: false` is the signed-out case: the row is still listed, and choosing it
    /// has to ask for a sign-in rather than switch to credentials that are not there.
    init(secondAccountUsable: Bool = true) throws {
        container = try ModelContainer(
            for: LoginAccount.self, LoginSession.self, LoginDeviceRegistration.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        viewModel = LoginViewModel(
            authService: NoopLoginAuthService(),
            providerInfoService: StubProviderInfoService(),
            sessionRegistry: registry
        )
        viewModel.modelContext = container.mainContext

        accountA = makeLoginAccountForTesting(email: "a@example.com", displayName: "Account A", userId: "user-a")
        accountB = makeLoginAccountForTesting(email: "b@example.com", displayName: "Account B", userId: "user-b", isActive: false)
        sessionA = makeLoginSessionForTesting(accountEmail: accountA.email, id: "chooser-session-a", userId: "user-a")
        sessionB = makeLoginSessionForTesting(accountEmail: accountB.email, id: "chooser-session-b", userId: "user-b")
        container.mainContext.insert(accountA)
        container.mainContext.insert(accountB)
        container.mainContext.insert(sessionA)
        container.mainContext.insert(sessionB)
        viewModel.accounts = [accountA, accountB]
        viewModel.sessions = [sessionA, sessionB]
        if !secondAccountUsable {
            sessionB.purgeTokens()
        }
        viewModel.refreshSignedOutAccounts()
    }

    func tearDown() {
        sessionA.purgeTokens()
        sessionB.purgeTokens()
    }

    func ownGameSession() -> OPNGameSession? {
        registry.begin(
            account: accountA,
            session: sessionA,
            gameService: OPNGameService.shared,
            launchBridge: OPNGameLaunchBridge.shared,
            discordPresence: DiscordRichPresence.shared,
            streamProfile: OPNStreamPreferenceProfile()
        )
    }
}

@MainActor
@Suite(.serialized)
struct AccountChooserTests {
    /// The stored startup preference, so a test that writes it puts the machine back as it found it.
    private func preserveStartupPreference() -> Bool? {
        guard OPNAppPreferenceStorage.standard.object(forKey: OPNAccountPreferences.shouldAskWhichAccountOnStartupKey) != nil else {
            return nil
        }
        return OPNAccountPreferences.shouldAskWhichAccountOnStartup
    }

    private func restoreStartupPreference(_ stored: Bool?) {
        guard let stored else {
            OPNAppPreferenceStorage.standard.removeObject(forKey: OPNAccountPreferences.shouldAskWhichAccountOnStartupKey)
            return
        }
        OPNAccountPreferences.shouldAskWhichAccountOnStartup = stored
    }

    // MARK: - The stored preference

    /// Off for anyone who never touched it, which is what keeps this from changing how an existing
    /// install starts.
    @Test func theStartupChooserPreferenceDefaultsToOff() {
        let stored = preserveStartupPreference()
        defer { restoreStartupPreference(stored) }
        OPNAppPreferenceStorage.standard.removeObject(forKey: OPNAccountPreferences.shouldAskWhichAccountOnStartupKey)

        #expect(!OPNAccountPreferences.shouldAskWhichAccountOnStartup)
    }

    @Test func theStartupChooserPreferenceRoundTrips() {
        let stored = preserveStartupPreference()
        defer { restoreStartupPreference(stored) }

        OPNAccountPreferences.shouldAskWhichAccountOnStartup = true
        #expect(OPNAccountPreferences.shouldAskWhichAccountOnStartup)

        OPNAccountPreferences.shouldAskWhichAccountOnStartup = false
        #expect(!OPNAccountPreferences.shouldAskWhichAccountOnStartup)
    }

    /// The preference needs something to ask about. One saved account and none are both ordinary
    /// startups, whatever the preference says.
    @Test func theStartupChooserNeedsMoreThanOneSavedAccount() {
        let stored = preserveStartupPreference()
        defer { restoreStartupPreference(stored) }
        OPNAccountPreferences.shouldAskWhichAccountOnStartup = true

        #expect(!OPNAccountPreferences.shouldAskOnStartup(savedAccountCount: 0))
        #expect(!OPNAccountPreferences.shouldAskOnStartup(savedAccountCount: 1))
        #expect(OPNAccountPreferences.shouldAskOnStartup(savedAccountCount: 2))
    }

    // MARK: - The startup gate

    @Test func aFreshLaunchDoesNotAskUnlessTheReaderAsked() throws {
        let stored = preserveStartupPreference()
        defer { restoreStartupPreference(stored) }
        OPNAccountPreferences.shouldAskWhichAccountOnStartup = false

        let fixture = try ChooserFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.bootstrap()

        #expect(fixture.viewModel.accountChooserReason == nil)
    }

    @Test func aFreshLaunchAsksWhenTheReaderOptedIn() throws {
        let stored = preserveStartupPreference()
        defer { restoreStartupPreference(stored) }
        OPNAccountPreferences.shouldAskWhichAccountOnStartup = true

        let fixture = try ChooserFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.bootstrap()

        #expect(fixture.viewModel.accountChooserReason == .startup)
    }

    /// One saved account is not a choice. The preference stays on, and the ordinary startup is kept.
    @Test func oneSavedAccountKeepsTheOrdinaryStartup() throws {
        let stored = preserveStartupPreference()
        defer { restoreStartupPreference(stored) }
        OPNAccountPreferences.shouldAskWhichAccountOnStartup = true

        let fixture = try ChooserFixture()
        defer { fixture.tearDown() }
        fixture.viewModel.accounts = [fixture.accountA]

        fixture.viewModel.bootstrap()

        #expect(fixture.viewModel.accountChooserReason == nil)
    }

    /// The promise that makes the startup chooser safe to ship: cancelling picks nothing. The account
    /// that was already selected stays selected, and every saved session stays usable.
    @Test func cancellingTheStartupChooserKeepsTheSelectedAccount() throws {
        let stored = preserveStartupPreference()
        defer { restoreStartupPreference(stored) }
        OPNAccountPreferences.shouldAskWhichAccountOnStartup = true

        let fixture = try ChooserFixture()
        defer { fixture.tearDown() }
        fixture.viewModel.bootstrap()
        let selectedBefore = fixture.viewModel.activeAccount?.email

        fixture.viewModel.dismissAccountChooser()

        #expect(fixture.viewModel.accountChooserReason == nil)
        #expect(fixture.viewModel.activeAccount?.email == selectedBefore)
        #expect(fixture.viewModel.activeAccount?.email == fixture.accountA.email)
        #expect(fixture.viewModel.hasUsableSession(for: fixture.accountA))
        #expect(fixture.viewModel.hasUsableSession(for: fixture.accountB))
    }

    // MARK: - "Switch account…"

    @Test func theProfileMenuOpensTheChooserWithSavedAccounts() throws {
        let fixture = try ChooserFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.presentAccountChooser()

        #expect(fixture.viewModel.accountChooserReason == .switchAccount)
    }

    /// With nothing saved there is nothing to choose between, so the menu item goes straight to
    /// adding one instead of opening an empty panel.
    @Test func theProfileMenuAddsAnAccountWhenNothingIsSaved() throws {
        let fixture = try ChooserFixture()
        defer { fixture.tearDown() }
        fixture.viewModel.accounts = []
        fixture.viewModel.sessions = []

        fixture.viewModel.presentAccountChooser()

        #expect(fixture.viewModel.accountChooserReason == nil)
        #expect(fixture.viewModel.signInRequest == .addAccount)
    }

    /// A signed-out selection requires authentication, and the account that is still signed in keeps
    /// its session.
    @Test func choosingASignedOutAccountAsksForSignInInsteadOfSwitching() throws {
        let fixture = try ChooserFixture(secondAccountUsable: false)
        defer { fixture.tearDown() }
        fixture.viewModel.presentAccountChooser()

        fixture.viewModel.activateAccount(fixture.accountB)

        #expect(fixture.viewModel.signInRequest == .reauthenticate(email: fixture.accountB.email))
        #expect(fixture.viewModel.accountChooserReason == nil)
        #expect(fixture.viewModel.activeAccount?.email == fixture.accountA.email)
        #expect(fixture.viewModel.hasUsableSession(for: fixture.accountA))
    }

    // MARK: - The switch notice

    @Test func theNoticeNamesBothAccountsWhileAGameKeepsRunning() throws {
        let fixture = try ChooserFixture()
        defer { fixture.tearDown() }
        _ = try #require(fixture.ownGameSession())

        fixture.viewModel.announceRunningGameContinues(with: fixture.accountB)

        let notice = try #require(fixture.viewModel.accountSwitchNotice)
        #expect(notice.contains("Account B"))
        #expect(notice.contains("Account A"))
    }

    /// No notice when the game belongs to the account being browsed: nothing changed, and saying so
    /// would be noise.
    @Test func thereIsNoNoticeWhenTheBrowsingAccountOwnsTheGame() throws {
        let fixture = try ChooserFixture()
        defer { fixture.tearDown() }
        _ = try #require(fixture.ownGameSession())

        fixture.viewModel.announceRunningGameContinues(with: fixture.accountA)

        #expect(fixture.viewModel.accountSwitchNotice == nil)
    }

    /// A preference is a preference. Turning the startup chooser on or off touches no session and no
    /// account: a game that is running keeps its owner, its credentials and its window.
    @Test func changingTheStartupPreferenceLeavesARunningGameAlone() throws {
        let stored = preserveStartupPreference()
        defer { restoreStartupPreference(stored) }
        let fixture = try ChooserFixture()
        defer { fixture.tearDown() }
        let game = try #require(fixture.ownGameSession())
        game.configuration = StreamLaunchConfiguration(
            title: "Cyberpunk 2077",
            applicationID: "1093630001",
            accessToken: "token-a",
            accountLinked: true,
            selectedStore: "steam"
        )
        let accountAID = try #require(fixture.accountA.storedAccountID)

        OPNAccountPreferences.shouldAskWhichAccountOnStartup = true
        OPNAccountPreferences.shouldAskWhichAccountOnStartup = false

        #expect(fixture.registry.sessions.contains { $0 === game })
        #expect(fixture.registry.isOwned(by: accountAID))
        #expect(game.configuration?.title == "Cyberpunk 2077")
        #expect(fixture.viewModel.accountChooserReason == nil)
    }
}
