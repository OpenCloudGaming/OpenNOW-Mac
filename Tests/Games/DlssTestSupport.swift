//  The doubles the DLSS suites share: a queued transport, a gated transport, an in-memory cache, a
//  hand-driven clock, a hand-driven announcement scheduler, and a preference guard.

import Foundation
import Testing
@testable import OpenNOW

/// A transport that hands back queued results in order, optionally after a delay.
final class DlssStubTransport: DlssCompatibilityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<Data, any Error>]
    private var requests = 0
    private let delay: TimeInterval

    init(_ queued: [Result<Data, any Error>], delay: TimeInterval = 0) {
        self.queued = queued
        self.delay = delay
    }

    var requestCount: Int {
        lock.withLock { requests }
    }

    func fetchList(url: URL, timeout: TimeInterval) async throws -> Data {
        let response = lock.withLock { () -> Result<Data, any Error>? in
            requests += 1
            return queued.isEmpty ? nil : queued.removeFirst()
        }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        guard let response else { throw DlssCompatibilityFetchError.transport("no queued response") }
        return try response.get()
    }
}

/// A transport whose single fetch can be held open until the test releases it, so a "late result" is
/// produced on demand rather than by racing a real delay.
final class DlssGatedTransport: DlssCompatibilityTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let rows: [DlssGamesRow]
    private let isReleasedImmediately: Bool
    private var isRequested = false
    private var requests = 0
    private var isReleased = false
    private var gate: CheckedContinuation<Void, Never>?

    init(rows: [DlssGamesRow], isReleasedImmediately: Bool = false) {
        self.rows = rows
        self.isReleasedImmediately = isReleasedImmediately
    }

    /// How many fetches the service has started.
    var requestCount: Int {
        lock.withLock { requests }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isReleased = true
            let continuation = gate
            gate = nil
            return continuation
        }
        continuation?.resume()
    }

    func waitUntilRequested() async {
        while lock.withLock({ !isRequested }) {
            await Task.yield()
        }
    }

    func fetchList(url: URL, timeout: TimeInterval) async throws -> Data {
        lock.withLock { requests += 1 }
        if !isReleasedImmediately {
            await waitForRelease()
        }
        lock.withLock { isRequested = true }
        return try Self.document(rows: rows)
    }

    private func waitForRelease() async {
        await withCheckedContinuation { continuation in
            let isAlreadyReleased = lock.withLock { () -> Bool in
                isRequested = true
                if isReleased { return true }
                gate = continuation
                return false
            }
            if isAlreadyReleased { continuation.resume() }
        }
    }

    private static func document(rows: [DlssGamesRow]) throws -> Data {
        let columns = DlssCompatibilityLimits.listColumns
        let data = rows.map { row -> [String: Any] in
            var value: [String: Any] = ["sno": 1, "name": row.title, "type": "Game"]
            value[columns[0]] = cellText(for: row.gameSupport?.superResolution)
            value[columns[1]] = cellText(for: row.gameSupport?.frameGeneration)
            value[columns[2]] = multiplierCellText(for: row.gameSupport?.multiFrameGeneration)
            value[columns[3]] = cellText(for: row.gameSupport?.rayReconstruction)
            value[columns[4]] = cellText(for: row.gameSupport?.dlaa)
            return value
        }
        return try JSONSerialization.data(withJSONObject: ["columns": [], "footer": "", "data": data])
    }

    private static func cellText(for support: DlssSupport?) -> String {
        switch support {
        case .native: "Yes"
        case .override: "NV, T"
        case nil: ""
        }
    }

    private static func multiplierCellText(for multiFrameGeneration: DlssMultiFrameGeneration?) -> String {
        guard let multiFrameGeneration else { return "" }
        return "NV, \(multiFrameGeneration.maxMultiplier)X"
    }
}

final class DlssMemoryCache: DlssCompatibilityCacheStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DlssCachedList?

    init(_ stored: DlssCachedList? = nil) {
        self.stored = stored
    }

    func load() -> DlssCachedList? {
        lock.withLock { stored }
    }

    func save(_ list: DlssCachedList) {
        lock.withLock { stored = list }
    }
}

/// A clock the test moves by hand. Its sleep returns immediately, so a bounded wait that is not under
/// test costs nothing.
final class DlssTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.date = date
    }

    var now: Date {
        lock.withLock { date }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(seconds) }
    }

    var compatibilityClock: DlssCompatibilityClock {
        DlssCompatibilityClock(now: { [self] in now }, sleep: { _ in })
    }
}

/// A clock whose sleep the test releases by hand, so a bounded wait is asserted from what the
/// service asked for rather than from how long the machine took.
final class DlssControlledClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleepCount = 0
    private var isSleepReleased = false

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = date
    }

    var now: Date {
        lock.withLock { current }
    }

    /// How many bounded waits the service has entered.
    var sleeps: Int {
        lock.withLock { sleepCount }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    /// Returns once the service is inside its bounded wait.
    func waitUntilSleeping() async {
        while lock.withLock({ sleepCount }) == 0 {
            await Task.yield()
        }
    }

    func releaseSleeps() {
        lock.withLock { isSleepReleased = true }
    }

    var compatibilityClock: DlssCompatibilityClock {
        DlssCompatibilityClock(now: { [self] in now }, sleep: { [self] _ in await waitForRelease() })
    }

    private func waitForRelease() async {
        lock.withLock { sleepCount += 1 }
        while !lock.withLock({ isSleepReleased }) {
            await Task.yield()
        }
    }
}

/// A scheduler the test drives by hand: nothing fires until `advance(by:)` passes its due time.
@MainActor
final class DlssVirtualScheduler: DlssAnnouncementScheduling {
    private struct Item {
        let id: Int
        let due: TimeInterval
        let action: @MainActor () -> Void
    }

    private var now: TimeInterval = 0
    private var items: [Item] = []
    private var cancelledIDs: Set<Int> = []
    private var nextID = 0

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> DlssAnnouncementTicket {
        let id = nextID
        nextID += 1
        items.append(Item(id: id, due: now + delay, action: action))
        return DlssAnnouncementTicket { [weak self] in
            self?.cancelledIDs.insert(id)
        }
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        while let due = items.filter({ !cancelledIDs.contains($0.id) && $0.due <= now }).min(by: { $0.due < $1.due }) {
            items.removeAll { $0.id == due.id }
            due.action()
        }
    }
}

/// Runs `body` with the two DLSS preference keys cleared, then restores whatever was there.
func withDlssPreferencesPreserved(_ body: () throws -> Void) rethrows {
    preferenceDomainTestLock.lock()
    defer { preferenceDomainTestLock.unlock() }
    let defaults = UserDefaults.standard
    let keys = ["OpenNOW.Stream.DlssOverrides", "OpenNOW.Stream.DlssEntitlements"]
    let previous = keys.map { ($0, defaults.object(forKey: $0)) }
    defer {
        for (key, value) in previous {
            if let value {
                defaults.set(value, forKey: key)
                continue
            }
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
    }
    for key in keys { defaults.removeObject(forKey: key) }
    try body()
}

/// Builds one list row in the shape NVIDIA publishes.
func makeDlssListRow(_ title: String, _ cells: [String]) -> DlssGamesRow {
    DlssGamesRow(title: title, gameSupport: DlssGamesListParser.gameSupport(from: cells))
}

/// Builds a document in the shape NVIDIA publishes.
func makeDlssListDocument(_ rows: [[String: Any]]) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["columns": [], "footer": "", "data": rows])) ?? Data()
}

/// Builds one raw row entry for `makeDlssListDocument`.
func makeDlssRawRow(_ name: Any, _ cells: [String], type: String = "Game") -> [String: Any] {
    var value: [String: Any] = ["sno": 1, "name": name, "type": type, "ray tracing": "", "ai": ""]
    for (index, column) in DlssCompatibilityLimits.listColumns.enumerated() where cells.indices.contains(index) {
        value[column] = cells[index]
    }
    return value
}
