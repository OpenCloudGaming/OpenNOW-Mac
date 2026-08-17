import Foundation

enum CIWindowTestGate {
    static let isHostedRunner = ProcessInfo.processInfo.environment["CI"] == "true"
    static let skipReason = "Creates real AppKit windows/views; unstable under swiftpm-testing-helper on hosted runners (use-after-free in deferred main-queue work). Run locally."
}
