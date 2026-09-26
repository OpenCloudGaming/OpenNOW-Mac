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

/// Serialises every writer of the shared `OPNStreamPreferences` domain; recursive because the
/// Remote Co-Op fixture writes keys from inside its own preserve block.
let preferenceDomainTestLock = NSRecursiveLock()

/// Runs `body` as the only writer of the shared preference domain. Use this instead of touching
/// `preferenceDomainTestLock` directly: an unwrapped writer is what made these suites flaky.
func withExclusivePreferenceDomain<Result>(_ body: () throws -> Result) rethrows -> Result {
    preferenceDomainTestLock.lock()
    defer { preferenceDomainTestLock.unlock() }
    return try body()
}
