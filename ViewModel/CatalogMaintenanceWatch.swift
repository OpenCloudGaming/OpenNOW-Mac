//  Opt-in maintenance watching: the view-facing state and actions over `CatalogMaintenanceWatchStore`,
//  plus the hand-off that turns a poll's availability into an announcement.

import Foundation
import Observation

extension CatalogViewModel {
    /// The watch list as the store's own value type, so every add/remove/advance goes through the
    /// one place that normalizes and caps it. Views observe `maintenanceWatches`, the stored array.
    var maintenanceWatchStore: CatalogMaintenanceWatchStore {
        CatalogMaintenanceWatchStore(watches: maintenanceWatches)
    }

    /// The number of titles being watched, as the Dock badge and the Settings list read it.
    var watchedTitleCount: Int { maintenanceWatches.count }

    /// Whether another watch could be added, so the UI can state the cap rather than discover it.
    var isMaintenanceWatchLimitReached: Bool { maintenanceWatchStore.isAtCapacity }

    func isWatching(_ game: OPNCatalogGameObject) -> Bool {
        maintenanceWatchStore.isWatching(Self.identity(for: game))
    }

    /// Reads the local watch list once at start and puts it in front of the poll and the Dock badge.
    func loadMaintenanceWatches() {
        applyMaintenanceWatchStore(.load(), immediatePoll: true)
    }

    /// The one toggle behind the mouse control and the pad action.
    func toggleMaintenanceWatch(for game: OPNCatalogGameObject) {
        guard isWatching(game) else {
            startWatchingMaintenance(for: game)
            return
        }
        removeMaintenanceWatch(identity: Self.identity(for: game))
    }

    /// Opts one maintenance-down title in. Only `.maintenance` carries a promise of returning;
    /// `.unavailable` does not.
    func startWatchingMaintenance(for game: OPNCatalogGameObject) {
        let identity = Self.identity(for: game)
        guard !identity.isEmpty else { return }
        guard game.catalogAvailability == .maintenance else { return }
        let addResult = maintenanceWatchStore.adding(
            identity: identity,
            appId: CatalogPatchStatusLogic.patchStatusAppId(game) ?? "",
            title: game.title,
            availability: .maintenance
        )
        guard addResult.isAdded else {
            setActionMessage("You are watching \(CatalogMaintenanceWatchStore.maximumCount) titles. Remove one to watch another.")
            return
        }
        applyMaintenanceWatchStore(addResult.store, immediatePoll: true)
        // Ask while the reader is looking at the control, so the system prompt lands in context.
        OPNMaintenanceWatchAction.prepareAuthorization()
        let title = game.title.isEmpty ? "this title" : game.title
        setActionMessage("Watching \(title). OpenNOW will let you know when it is playable again.")
    }

    func removeMaintenanceWatch(identity: String) {
        guard maintenanceWatchStore.isWatching(identity) else { return }
        let title = maintenanceWatchStore.watch(for: identity)?.title ?? ""
        applyMaintenanceWatchStore(maintenanceWatchStore.removing(identity: identity), immediatePoll: false)
        setActionMessage(title.isEmpty ? "Stopped watching that title." : "Stopped watching \(title).")
    }

    func clearMaintenanceWatches() {
        guard !maintenanceWatches.isEmpty else { return }
        applyMaintenanceWatchStore(maintenanceWatchStore.removingAll(), immediatePoll: false)
        setActionMessage("Stopped watching every title.")
    }

    /// Turns one poll's availability into announced edges. Called after `applyPatchingStatuses`, so
    /// the game graph already carries the polled availability this reads.
    func advanceMaintenanceWatches(statuses: [String: OPNAppPatchStatus]) {
        guard !maintenanceWatches.isEmpty else { return }
        let advanceResult = maintenanceWatchStore.advancing(availabilityByIdentity: availabilityByIdentity(statuses: statuses))
        guard !advanceResult.events.isEmpty else {
            storeAdvancedObservations(advanceResult.store)
            return
        }
        applyMaintenanceWatchStore(advanceResult.store, immediatePoll: false)
        handleMaintenanceWatchEvents(advanceResult.events)
    }

    /// A watched title's availability from the game graph, falling back to the poll's own status keyed
    /// by the app id the watch stored, for a title the loaded catalog does not contain.
    private func availabilityByIdentity(statuses: [String: OPNAppPatchStatus]) -> [String: CatalogAvailability] {
        var availability: [String: CatalogAvailability] = [:]
        for watch in maintenanceWatches {
            let game = allKnownGames.first { Self.identity(for: $0) == watch.identity }
            availability[watch.identity] = game?.catalogAvailability ?? statuses[watch.appId]?.availability
        }
        return availability
    }

    /// Persists the poll's bookkeeping when no edge fired, without rescheduling anything.
    private func storeAdvancedObservations(_ store: CatalogMaintenanceWatchStore) {
        guard store.watches != maintenanceWatches else { return }
        applyMaintenanceWatchStore(store, immediatePoll: false)
    }

    private func handleMaintenanceWatchEvents(_ events: [CatalogMaintenanceWatchEvent]) {
        // The patching edge hands off to the queued auto-launch the reader already opted into by
        // watching: when patching finishes, the same machinery launches it and says so.
        for event in events where event.edge == .patching {
            guard let game = allKnownGames.first(where: { Self.identity(for: $0) == event.watch.identity }) else { continue }
            guard !isQueuedForPatching(game) else { continue }
            queuePatchingLaunch(game: game)
        }
        // Frontmost: no bounce to make, so the status line carries it instead.
        if let message = OPNMaintenanceWatchAction.announce(events) {
            setActionMessage(message)
        }
    }

    /// Auth can no longer be refreshed, so a watch's promise cannot be kept. Stopping and saying so
    /// beats a watch that never fires and never explains why.
    func stopMaintenanceWatchesForUnrecoverableAuth() {
        guard !maintenanceWatches.isEmpty else { return }
        applyMaintenanceWatchStore(maintenanceWatchStore.removingAll(), immediatePoll: false)
        errorMessage = "Unable to refresh your NVIDIA session, so OpenNOW stopped watching your games. Sign out and sign in again."
    }

    private func applyMaintenanceWatchStore(_ store: CatalogMaintenanceWatchStore, immediatePoll: Bool) {
        maintenanceWatches = store.watches
        store.save()
        OPNDockIconController.setWatchedTitleCount(store.watches.count)
        // Rescheduling is what starts the poll for a first watch and what stops it when the last
        // one goes: the poll set is empty once neither patching nor watches remain.
        schedulePatchingPollIfNeeded(immediate: immediatePoll)
    }
}
