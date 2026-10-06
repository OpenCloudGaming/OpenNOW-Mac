//  Owns the catalog view model's long-lived resources, so releasing the view model releases them
//  here rather than in a `deinit` that cannot reach main-actor state.
//

import Foundation

final class CatalogViewModelDeinitHandle: @unchecked Sendable {
    var patchingPollTask: Task<Void, Never>?
    var collectionsStoreObserver: NSObjectProtocol?
    var homeArrangementObserver: NSObjectProtocol?
    /// The finished-session results this catalog is waiting on, tagged for its account. The only
    /// thing a disappearing catalog releases: nothing here may end a session that outlives it.
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
