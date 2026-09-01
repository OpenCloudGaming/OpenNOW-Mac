import Foundation

actor NetworkTestIsolationLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard !waiters.isEmpty else {
            locked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

let networkTestIsolationLock = NetworkTestIsolationLock()

/// Serialises tests that write `OPNStreamPreferences`.
///
/// Those preferences are one process-wide `UserDefaults` store, so two tests that both write the
/// transport mode race whatever their own save/restore bookkeeping does: one test's restore lands in
/// the middle of the other's read-back. The failure is timing-dependent and shows up as a completely
/// unrelated assertion - a coordinator rejecting a session for the wrong reason - so it reads as a
/// flake in whichever test happened to lose.
let streamPreferencesTestIsolationLock = NetworkTestIsolationLock()


/// Serialises test helpers that snapshot and restore an entire `UserDefaults` persistent domain.
///
/// `setPersistentDomain` is a whole-domain write, so two helpers doing snapshot-modify-restore lose
/// each other's keys - and worse, one can *resurrect* a key the other has just cleared, because a
/// stale snapshot is written back wholesale. `OPNAppPreferenceStorage.storedValue` prefers the
/// canonical domain, so a resurrected key wins over the default a test is asserting on. The failure
/// surfaces far away: an upscaling test reading a value a Remote Co-Op fixture put back.
///
/// Recursive because the Remote Co-Op fixture writes individual keys from inside its own preserve
/// block.
let preferenceDomainTestLock = NSRecursiveLock()
