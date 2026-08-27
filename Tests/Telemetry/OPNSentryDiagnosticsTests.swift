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

    OPNSentry.clearDiagnosticsLog(at: logURL)

    let data = try Data(contentsOf: logURL)
    #expect(data.isEmpty)
}

@Test func clearDiagnosticsLogCreatesMissingParentDirectory() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("nested", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let logURL = directory.appendingPathComponent("OpenNOW-diagnostics-current.log")
    OPNSentry.clearDiagnosticsLog(at: logURL)

    let data = try Data(contentsOf: logURL)
    #expect(data.isEmpty)
}

@Test func sanitizedLogMessageOnlyRedactsIPAddresses() {
    let message = "email=user@example.com phone=+1 555 123 4567 id=550E8400-E29B-41D4-A716-446655440000 token=abc.def.ghi ipv4=192.168.1.24 ipv6=2600:1702:7b40:6190:69ea:cb80:cf15:6289"
    let sanitized = OPNSentry.sanitizedLogMessage(message)

    #expect(sanitized.contains("user@example.com"))
    #expect(sanitized.contains("+1 555 123 4567"))
    #expect(sanitized.contains("550E8400-E29B-41D4-A716-446655440000"))
    #expect(sanitized.contains("abc.def.ghi"))
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
