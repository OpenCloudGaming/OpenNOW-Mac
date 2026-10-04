//  Owns the catalog view model's long-lived resources, so releasing the view model releases them
//  here rather than in a `deinit` that cannot reach main-actor state.
//

import Foundation

final class CatalogViewModelDeinitHandle: @unchecked Sendable {
    var patchingPollTask: Task<Void, Never>?
    var collectionsStoreObserver: NSObjectProtocol?
    var homeArrangementObserver: NSObjectProtocol?
    /// The finished-session results this catalog is waiting on, tagged for its account.
    ///
    /// Deliberately the only thing a disappearing catalog releases. A game session outlives the
    /// catalog that started it - that is what lets an accepted launch and a running stream survive a
    /// browsing switch - so nothing here may end one.
    var sessionResultObserver: NSObjectProtocol?

    deinit {
        if let collectionsStoreObserver {
            NotificationCenter.default.removeObserver(collectionsStoreObserver)
        }
        if let homeArrangementObserver {
            NotificationCenter.default.removeObserver(homeArrangementObserver)
        }
        if let sessionResultObserver {
            NotificationCenter.default.removeObserver(sessionResultObserver)
        }
        patchingPollTask?.cancel()
    }
}
