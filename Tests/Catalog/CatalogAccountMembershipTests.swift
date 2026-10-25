import Foundation
import SwiftData
import Testing
@testable import OpenNOW

@MainActor
@Suite struct CatalogAccountMembershipTests {
    private let preferenceKeys = ["OpenNOW.Stream.DlssEntitlements", "OpenNOW.Stream.EntitledAudioChannelCount", "OpenNOW.Stream.EntitledInGameSettingsPersistence"]

    @Test func anInactiveAuthenticatedCatalogLoadsItsOwnMembershipWithoutChangingTheActiveAccount() {
        withPreservedPreferences(preferenceKeys) {
            let active = makeCatalog(email: "active@example.test", isActive: true)
            let detached = makeCatalog(email: "detached@example.test", isActive: false)
            let activeMembership = subscription(tier: "Ultimate", channels: 8, isEntitled: true)
            OPNStreamPreferences.saveDlssEntitlements(activeMembership.dlssEntitlements)
            defer {
                active.model.session.purgeTokens()
                detached.model.session.purgeTokens()
            }
            active.model.loadAccount()
            detached.model.loadAccount()
            #expect(active.model.dlssMembershipState == .loading)
            #expect(detached.model.dlssMembershipState == .loading)
            #expect(OPNStreamPreferences.loadDlssEntitlements() == activeMembership.dlssEntitlements)

            active.service.completeSubscription(at: 0, subscription: activeMembership)
            detached.service.completeSubscription(at: 0, subscription: subscription(tier: "Free", channels: 2, isEntitled: false))

            #expect(detached.model.account.membershipTier == "Free")
            #expect(detached.model.dlssMembershipState == .loaded(.none))
            #expect(active.model.account.membershipTier == "Ultimate")
            #expect(active.model.launchEntitlements.audioChannelCount == 8)
            #expect(detached.model.launchEntitlements.audioChannelCount == 2)
            #expect(OPNStreamPreferences.loadDlssEntitlements() == active.model.launchEntitlements.dlss)
            #expect(OPNStreamPreferences.loadEntitledAudioChannelCount() == 8)
            #expect(OPNStreamPreferences.loadEntitledInGameSettingsPersistence())
        }
    }

    enum Invalidation: CaseIterable, Sendable {
        case signOut, deleteAccount, deleteSession, replaceCredentials, replaceProvider
    }

    @Test(arguments: Invalidation.allCases)
    func anInvalidatedCatalogRejectsLateMembership(_ invalidation: Invalidation) throws {
        let container = try ModelContainer(for: LoginAccount.self, LoginSession.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let catalog = makeCatalog(email: "late-\(invalidation)@example.test", isActive: false)
        container.mainContext.insert(catalog.model.account)
        container.mainContext.insert(catalog.model.session)
        defer {
            if invalidation != .deleteSession { catalog.model.session.purgeTokens() }
        }
        catalog.model.loadAccount()
        #expect(catalog.service.subscriptionRequestCount == 1)
        switch invalidation {
        case .signOut:
            catalog.model.session.purgeTokens()
        case .deleteAccount:
            container.mainContext.delete(catalog.model.account)
            try container.mainContext.save()
        case .deleteSession:
            catalog.model.session.purgeTokens()
            container.mainContext.delete(catalog.model.session)
            try container.mainContext.save()
        case .replaceCredentials:
            catalog.model.session.idToken = "replacement-token"
        case .replaceProvider:
            catalog.model.session.idpId = "replacement-provider"
        }
        catalog.service.completeSubscription(at: 0, subscription: subscription(tier: "Ultimate", channels: 8, isEntitled: true))
        #expect(catalog.model.launchEntitlements == .none)
        #expect(catalog.model.dlssMembershipState == .loading)
    }

    @Test func replacingCredentialsCannotReusePreviouslyLoadedLaunchEntitlements() {
        let catalog = makeCatalog(email: "replaced@example.test", isActive: false)
        defer { catalog.model.session.purgeTokens() }
        catalog.model.loadAccount()
        catalog.service.completeSubscription(at: 0, subscription: subscription(tier: "Ultimate", channels: 8, isEntitled: true))
        #expect(catalog.model.currentLaunchEntitlements.audioChannelCount == 8)
        catalog.model.session.idToken = "replacement-token"
        #expect(catalog.model.currentLaunchEntitlements == .none)
    }

    @Test func aNewMembershipRequestCannotBeOverwrittenByAnOlderCompletion() {
        let catalog = makeCatalog(email: "reloaded@example.test", isActive: false)
        defer { catalog.model.session.purgeTokens() }
        catalog.model.loadAccount()
        catalog.model.loadAccount()
        catalog.service.completeSubscription(at: 1, subscription: subscription(tier: "Performance", channels: 6, isEntitled: false))
        catalog.service.completeSubscription(at: 0, subscription: subscription(tier: "Ultimate", channels: 8, isEntitled: true))
        #expect(catalog.model.account.membershipTier == "Performance")
        #expect(catalog.model.launchEntitlements.audioChannelCount == 6)
        #expect(catalog.model.dlssMembershipState == .loaded(.none))
    }

    @Test func anInactiveMembershipFailureFinishesCheckingWithoutClearingAnotherAccount() {
        withPreservedPreferences(preferenceKeys) {
            OPNStreamPreferences.saveDlssEntitlements(subscription(tier: "Ultimate", channels: 8, isEntitled: true).dlssEntitlements)
            let catalog = makeCatalog(email: "failed@example.test", isActive: false)
            defer { catalog.model.session.purgeTokens() }
            catalog.model.loadAccount()
            catalog.service.completeSubscription(at: 0, subscription: OPNSubscriptionInfo(), isSuccessful: false)
            #expect(catalog.model.dlssMembershipState == .unavailable)
            #expect(catalog.model.launchEntitlements == .none)
            #expect(OPNStreamPreferences.loadDlssEntitlements().superResolution.isEntitled)
        }
    }

    private func makeCatalog(email: String, isActive: Bool) -> (model: CatalogViewModel, service: CatalogAccountServiceStub) {
        let account = makeLoginAccountForTesting(email: email, userId: email, isActive: isActive)
        let session = makeLoginSessionForTesting(accountEmail: email, userId: email)
        session.isActive = isActive
        let service = CatalogAccountServiceStub()
        return (CatalogViewModel(account: account, session: session, gameService: service, onRefreshAuth: { false }), service)
    }

    private func subscription(tier: String, channels: Int, isEntitled: Bool) -> OPNSubscriptionInfo {
        var subscription = OPNSubscriptionInfo()
        subscription.membershipTier = tier
        subscription.entitledAudioChannelCount = channels
        subscription.isInGameSettingsPersistenceEntitled = isEntitled
        if isEntitled { subscription.dlssEntitlements = DlssEntitlements(superResolution: DlssCapability(isEntitled: true)) }
        return subscription
    }
}
