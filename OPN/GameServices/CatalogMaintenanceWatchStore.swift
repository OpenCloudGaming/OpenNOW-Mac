//  The titles this Mac is watching for maintenance to end. There is no vendor endpoint for a
//  watch and no Mac other than this one can honour it, so it is stored locally and never reaches
//  iCloud — the same reasoning `OPNCloudSyncSettingsRegistry.deniedKeys` documents for values bound
//  to one machine. A watch is keyed on a title's `catalogIdentity`, so every edition and storefront
//  of a title shares one watch.

import Foundation

/// The two moments a maintenance watch can announce: maintenance ended into patching, or the title
/// is actually playable again. Kept as raw values because the store persists the last one notified.
enum CatalogMaintenanceWatchEdge: String, Codable, Equatable, Sendable {
    case patching
    case available
}

/// One watched title. `observedAvailability` is what the last poll saw, held so the next poll can
/// tell a real edge from a status that never moved; `lastNotifiedEdge` suppresses a duplicate when
/// the vendor's status flaps, while a removed-and-re-added watch starts fresh and can fire again.
struct CatalogMaintenanceWatch: Codable, Equatable, Identifiable, Sendable {
    var identity: String
    var appId: String
    var title: String
    var startedAt: Date
    var observedAvailability: CatalogAvailability
    var lastNotifiedEdge: CatalogMaintenanceWatchEdge?

    var id: String { identity }
}

/// The local watch list, stored as JSON under one key and capped. An empty list clears the key.
/// Every write and load passes through `sanitized(_:)`, so what is stored can be stored again, and
/// one malformed record cannot discard the rest.
struct CatalogMaintenanceWatchStore: Equatable {
    static let storageKey = "OpenNOW.Catalog.MaintenanceWatches"
    /// The hard ceiling on simultaneous watches. It is stated in the UI rather than discovered: the
    /// poll fetches every watched title, and past this many the reader is better served removing one
    /// than adding another.
    static let maximumCount = 25

    /// Posted after the watch list is written, so a live view model that read it earlier re-reads it.
    static let didChangeNotification = Notification.Name("OPNCatalogMaintenanceWatchStoreDidChange")

    static let empty = CatalogMaintenanceWatchStore()

    let watches: [CatalogMaintenanceWatch]

    init(watches: [CatalogMaintenanceWatch] = []) {
        self.watches = Self.sanitized(watches)
    }

    var isAtCapacity: Bool { watches.count >= Self.maximumCount }

    func isWatching(_ identity: String) -> Bool {
        watch(for: identity) != nil
    }

    func watch(for identity: String) -> CatalogMaintenanceWatch? {
        guard !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return watches.first { $0.identity == identity }
    }

    /// Adding is refused at the cap rather than silently dropping another watch: the reader chose
    /// both, and only the reader can decide which one goes.
    func adding(identity: String, appId: String, title: String, availability: CatalogAvailability, now: Date = Date()) -> (store: CatalogMaintenanceWatchStore, added: Bool) {
        guard !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (self, false) }
        guard !isWatching(identity) else { return (self, false) }
        guard !isAtCapacity else { return (self, false) }
        let watch = CatalogMaintenanceWatch(
            identity: identity,
            appId: appId,
            title: title,
            startedAt: now,
            observedAvailability: availability,
            lastNotifiedEdge: nil
        )
        return (CatalogMaintenanceWatchStore(watches: watches + [watch]), true)
    }

    func removing(identity: String) -> CatalogMaintenanceWatchStore {
        CatalogMaintenanceWatchStore(watches: watches.filter { $0.identity != identity })
    }

    func removingAll() -> CatalogMaintenanceWatchStore {
        .empty
    }

    /// Advances the polling bookkeeping after a poll: the observation each watch now holds and the
    /// edges that have to be announced. Pure, so edge detection is testable without a poll.
    func advancing(availabilityByIdentity: [String: CatalogAvailability]) -> (store: CatalogMaintenanceWatchStore, events: [CatalogMaintenanceWatchEvent]) {
        var updated: [CatalogMaintenanceWatch] = []
        var events: [CatalogMaintenanceWatchEvent] = []
        for watch in watches {
            guard let availability = availabilityByIdentity[watch.identity] else {
                updated.append(watch)
                continue
            }
            if let edge = Self.edge(from: watch.observedAvailability, to: availability, lastNotified: watch.lastNotifiedEdge) {
                events.append(CatalogMaintenanceWatchEvent(watch: watch, edge: edge))
                // The ready edge is the promise being kept, so the watch ends there: it stops
                // counting toward the badge and leaves the Settings list. The patching edge keeps
                // the watch, which is still waiting on the title to finish patching.
                guard edge != .available else { continue }
                var announced = watch
                announced.lastNotifiedEdge = edge
                announced.observedAvailability = availability
                updated.append(announced)
                continue
            }
            var observed = watch
            observed.observedAvailability = availability
            updated.append(observed)
        }
        return (CatalogMaintenanceWatchStore(watches: updated), events)
    }

    /// The edge between two observations, or nil when nothing announcable happened. Patching is only
    /// an edge out of maintenance; ready is an edge out of anything that was not already ready. The
    /// last-notified record turns a flapping status into one announcement per edge.
    static func edge(from previous: CatalogAvailability, to current: CatalogAvailability, lastNotified: CatalogMaintenanceWatchEdge?) -> CatalogMaintenanceWatchEdge? {
        if current == .patching, previous == .maintenance {
            return lastNotified == .patching ? nil : .patching
        }
        if current == .available, previous != .available {
            return lastNotified == .available ? nil : .available
        }
        return nil
    }

    static func load() -> CatalogMaintenanceWatchStore {
        guard let data = OPNAppPreferenceStorage.syncStore.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([LossyWatch].self, from: data) else {
            return .empty
        }
        return CatalogMaintenanceWatchStore(watches: decoded.compactMap(\.value))
    }

    func save() {
        let storage = OPNAppPreferenceStorage.syncStore
        guard !watches.isEmpty else {
            guard storage.object(forKey: Self.storageKey) != nil else { return }
            storage.removeObject(forKey: Self.storageKey)
            announceChange()
            return
        }
        guard let data = try? JSONEncoder().encode(watches) else { return }
        guard storage.data(forKey: Self.storageKey) != data else { return }
        storage.set(data, forKey: Self.storageKey)
        announceChange()
    }

    /// Drops unusable records and the newest write per identity, then caps. The store's own writes
    /// already keep identity order, so a load restores what was saved.
    static func sanitized(_ watches: [CatalogMaintenanceWatch]) -> [CatalogMaintenanceWatch] {
        var seen = Set<String>()
        var result: [CatalogMaintenanceWatch] = []
        for watch in watches {
            let identity = watch.identity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identity.isEmpty, !seen.contains(identity) else { continue }
            seen.insert(identity)
            result.append(watch)
        }
        return Array(result.prefix(maximumCount))
    }

    private func announceChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

/// One title reaching one edge, as the announcer needs it.
struct CatalogMaintenanceWatchEvent: Equatable, Sendable {
    let watch: CatalogMaintenanceWatch
    let edge: CatalogMaintenanceWatchEdge
}

/// Decodes each array element independently, so one malformed watch cannot discard the rest.
private struct LossyWatch: Decodable {
    let value: CatalogMaintenanceWatch?

    init(from decoder: Decoder) throws {
        value = try? CatalogMaintenanceWatch(from: decoder)
    }
}
