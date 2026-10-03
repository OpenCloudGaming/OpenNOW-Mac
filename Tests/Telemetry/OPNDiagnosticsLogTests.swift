import Foundation
import Testing
@testable import OpenNOW

@Test func clearDiagnosticsLogTruncatesExistingFile() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let logURL = directory.appendingPathComponent("OpenNOW-diagnostics-current.log")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("previous-run-log".utf8).write(to: logURL)

    OPNDiagnostics.clearDiagnosticsLog(at: logURL)

    let data = try Data(contentsOf: logURL)
    #expect(data.isEmpty)
}

@Test func clearDiagnosticsLogCreatesMissingParentDirectory() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("nested", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let logURL = directory.appendingPathComponent("OpenNOW-diagnostics-current.log")
    OPNDiagnostics.clearDiagnosticsLog(at: logURL)

    let data = try Data(contentsOf: logURL)
    #expect(data.isEmpty)
}

/// The clear is the first statement of `OPNApp.init()`, and it is deliberately not synchronous: a
/// directory create plus an atomic truncate does not belong on the launch path before anything else
/// has run. Queueing it is safe because `diagnosticsLogQueue` is serial — the clear still lands
/// before every append submitted after it.
///
/// The log queue is held busy across the call so a synchronous clear could not return: this test
/// fails instead of passing if the clear is turned back into a `.sync`.
@Test func clearDiagnosticsLogForNewRunDoesNotBlockTheCaller() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let logURL = directory.appendingPathComponent("OpenNOW-diagnostics-current.log")
    try Data("previous-run-log".utf8).write(to: logURL)

    // Occupy the log queue and keep holding it until this test releases it. Waiting for the hold to
    // actually start is what stops the clear below from slipping in front of it and running at once.
    let queueIsBusy = DispatchSemaphore(value: 0)
    let releaseQueue = DispatchSemaphore(value: 0)
    OPNDiagnostics.diagnosticsLogQueue.async {
        queueIsBusy.signal()
        releaseQueue.wait()
    }
    queueIsBusy.wait()

    let clearReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        OPNDiagnostics.clearDiagnosticsLogForNewRun(at: logURL)
        clearReturned.signal()
    }
    let returnedWhileQueueWasBusy = clearReturned.wait(timeout: .now() + 5)
    #expect(returnedWhileQueueWasBusy == .success)
    // Queued behind the hold, so the previous run's log is still there.
    #expect(try Data(contentsOf: logURL).count > 0)

    // A line written after the clear, the way `appendDiagnosticsLogLine` writes one: on the same
    // serial queue. It must observe the clear.
    releaseQueue.signal()
    OPNDiagnostics.diagnosticsLogQueue.async {
        try? Data("first-line-of-new-run\n".utf8).write(to: logURL)
    }
    OPNDiagnostics.diagnosticsLogQueue.sync {}

    #expect(try String(contentsOf: logURL, encoding: .utf8) == "first-line-of-new-run\n")
}

/// Addresses and credentials are redacted; identifiers that make a log worth reading are not.
/// `token=` used to survive this, which is how a live `id_token_hint` reached the diagnostics
/// file and the paste service the upload path posts to.
@Test func sanitizedLogMessageRedactsAddressesAndCredentials() {
    let message = "email=user@example.com phone=+1 555 123 4567 id=550E8400-E29B-41D4-A716-446655440000 token=abc.def.ghi ipv4=192.168.1.24 ipv6=2600:1702:7b40:6190:69ea:cb80:cf15:6289"
    let sanitized = OPNDiagnostics.sanitizedLogMessage(message)

    #expect(sanitized.contains("user@example.com"))
    #expect(sanitized.contains("+1 555 123 4567"))
    #expect(sanitized.contains("550E8400-E29B-41D4-A716-446655440000"))
    #expect(!sanitized.contains("abc.def.ghi"))
    #expect(!sanitized.contains("192.168.1.24"))
    #expect(!sanitized.contains("2600:1702:7b40:6190:69ea:cb80:cf15:6289"))
}

@Test func networkLogURLKeepsDiagnosticQueryValues() throws {
    let url = try #require(URL(string: "https://gx-target-experiments-frontend-api.gx.nvidia.com/cloudvariables/v3?clientParams=%7B%22userDefaultUILanguage%22:%22en%22%7D&deviceId=abc123#debug"))
    let sanitized = OPNNetworkLog.sanitizedURL(url)

    #expect(sanitized.contains("clientParams="))
    #expect(sanitized.contains("userDefaultUILanguage"))
    #expect(sanitized.contains("deviceId=abc123"))
    #expect(sanitized.contains("#debug"))
}

@Test func networkLogURLRedactsIPAddressesOnly() throws {
    let url = try #require(URL(string: "https://192.168.1.24/v2/session/825d610c-e516-827a-40ad-a2c8e7205133?server=2600:1702:7b40:6190:69ea:cb80:cf15:6289"))
    let sanitized = OPNNetworkLog.sanitizedURL(url)

    #expect(!sanitized.contains("192.168.1.24"))
    #expect(!sanitized.contains("2600:1702:7b40:6190:69ea:cb80:cf15:6289"))
    #expect(sanitized.contains("825d610c-e516-827a-40ad-a2c8e7205133"))
}
