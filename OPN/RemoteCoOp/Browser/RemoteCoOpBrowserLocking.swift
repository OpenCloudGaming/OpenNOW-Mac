import Foundation

extension NSLock {
    /// Scoped locking that is callable from `async` contexts, where an unbalanced `lock()`/`unlock()`
    /// pair is rejected by the concurrency checker.
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
