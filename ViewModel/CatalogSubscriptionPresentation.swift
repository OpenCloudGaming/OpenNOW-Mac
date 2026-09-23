//  The membership tier the catalog chrome shows.

import Foundation

extension CatalogViewModel {
    /// The tier the chrome shows: live subscription data, else the account's saved tier, else the
    /// brand default. The saved tier is already correct at launch, so the badge never flashes.
    var displayMembershipTier: String {
        if subscriptionStatus.isAvailable, !subscriptionStatus.membershipTier.isEmpty {
            return subscriptionStatus.membershipTier
        }
        let savedTier = account.membershipTier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !savedTier.isEmpty {
            return savedTier
        }
        if !subscriptionStatus.membershipTier.isEmpty {
            return subscriptionStatus.membershipTier
        }
        return CatalogSubscriptionStatus.fallbackMembershipTier
    }
}
