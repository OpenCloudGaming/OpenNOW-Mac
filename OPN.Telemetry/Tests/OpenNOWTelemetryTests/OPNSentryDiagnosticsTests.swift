import Foundation
import Testing
@testable import OpenNOWTelemetry

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
