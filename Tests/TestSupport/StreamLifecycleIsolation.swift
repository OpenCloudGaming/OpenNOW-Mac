import Foundation
import Testing

/// Lock for tests that read or write `StreamSessionLifecycle`. `.serialized` orders one suite only,
/// so a suite holding a mounted stream across an await still races one asserting it is empty.
let streamLifecycleTestLock = NetworkTestIsolationLock()

/// Runs a test under `streamLifecycleTestLock`. Attach it to every suite that mounts a stream or
/// reads a state derived from one: `@Suite(.serialized, .streamLifecycleExclusive)`.
struct StreamLifecycleExclusiveTrait: SuiteTrait, TestScoping {
    func provideScope(for test: Test,
                      testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        try await streamLifecycleTestLock.withLock {
            try await function()
        }
    }
}

extension SuiteTrait where Self == StreamLifecycleExclusiveTrait {
    static var streamLifecycleExclusive: Self { StreamLifecycleExclusiveTrait() }
}
