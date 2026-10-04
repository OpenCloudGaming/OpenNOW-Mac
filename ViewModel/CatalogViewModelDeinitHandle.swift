//  Owns the catalog view model's long-lived resources, so releasing the view model releases them
//  here rather than in a `deinit` that cannot reach main-actor state.
//

import Foundation

final class CatalogViewModelDeinitHandle: @unchecked Sendable {
    var patchingPollTask: Task<Void, Never>?
    var collectionsStoreObserver: NSObjectProtocol?
    var homeArrangementObserver: NSObjectProtocol?
    /// The session ownership this catalog still held when it went away.
    ///
    /// A catalog is remounted whenever the selected session changes, and that remount ends the
    /// stream it was presenting without ever reaching `finishActiveStream` - the ownership would
    /// then outlive the game and keep its account blocked from signing out for the rest of the
    /// process's life. Released here as the backstop; the launch flow releases it on every path it
    /// does complete.
    var ownedGameSessionID: UUID?
    /// The registry the ownership above was claimed in. Set once, from the catalog's own injected
    /// registry, so the release lands in the same one the claim did.
    var registry: OPNGameSessionRegistry?

    deinit {
        if let collectionsStoreObserver {
            NotificationCenter.default.removeObserver(collectionsStoreObserver)
        }
        if let homeArrangementObserver {
            NotificationCenter.default.removeObserver(homeArrangementObserver)
        }
        patchingPollTask?.cancel()
        if let ownedGameSessionID, let registry {
            Task { @MainActor in registry.release(ownedGameSessionID) }
        }
    }
}
