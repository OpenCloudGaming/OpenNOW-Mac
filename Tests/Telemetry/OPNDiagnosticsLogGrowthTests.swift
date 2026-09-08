import Foundation
import Testing
@testable import OpenNOW

/// The trim used to cut back to exactly the ceiling, which left the file over it again on the very
/// next line: every write then read and rewrote the whole 8 MB. The stream transport logs counters
/// every two seconds, so a session reached that state in about an hour and stayed there.
@Test func diagnosticsTrimLeavesHeadroomBelowTheCeiling() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let logURL = directory.appendingPathComponent("OpenNOW-diagnostics-current.log")
    try Data(repeating: UInt8(ascii: "x"), count: OPNSentry.maxDiagnosticsLogBytes + 4096).write(to: logURL)

    OPNSentry.trimDiagnosticsLogIfNeeded(url: logURL, writtenBytes: OPNSentry.maxDiagnosticsLogBytes + 4096)

    let trimmed = try Data(contentsOf: logURL)
    #expect(trimmed.count == OPNSentry.trimmedDiagnosticsLogBytes)
    #expect(trimmed.count < OPNSentry.maxDiagnosticsLogBytes)
}

@Test func diagnosticsTrimLeavesAFileUnderTheCeilingAlone() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let logURL = directory.appendingPathComponent("OpenNOW-diagnostics-current.log")
    let contents = Data(repeating: UInt8(ascii: "x"), count: 1024)
    try contents.write(to: logURL)

    OPNSentry.trimDiagnosticsLogIfNeeded(url: logURL, writtenBytes: contents.count)

    #expect(try Data(contentsOf: logURL).count == contents.count)
}

/// Scrubbing is applied by the caller and again by every sink it reaches. Whatever else changes,
/// running it twice must not corrupt the text — the sinks rely on it being safe to repeat.
@Test func sanitizingAnAlreadySanitizedMessageChangesNothing() {
    let message = "auth Bearer abcdefghijklmnop ip=192.168.1.24 note=keep-me"
    let once = OPNSentry.sanitizedLogMessage(message)
    let twice = OPNSentry.sanitizedLogMessage(once)

    #expect(once == twice)
    #expect(once.contains("keep-me"))
    #expect(!once.contains("192.168.1.24"))
}

/// A session log that never stops growing is what age-based pruning alone allowed: an hour of
/// streaming is roughly 8 MB of counter lines, and the retention sweep only looks at dates.
@Test func nvstDiagnosticLogStopsAtItsCeiling() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let budget = 64 * 1024
    let log = NvstDiagnosticLog(directory: directory, fileBudget: budget)
    let url = try #require(log.url)
    let line = String(repeating: "n", count: 4 * 1024)
    for _ in 0..<((budget / line.utf8.count) + 8) {
        log.append(line)
    }
    log.queue.sync {}

    let size = try #require((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber).intValue
    #expect(size >= budget)
    #expect(size < budget + 2 * line.utf8.count)
    #expect(try String(contentsOf: url, encoding: .utf8).contains("reached its"))
}

/// Old sessions are dropped by size as well as by age, oldest first.
@Test func nvstDiagnosticLogPrunesTheDirectoryToItsBudget() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let budget = 128 * 1024
    let chunk = Data(repeating: UInt8(ascii: "x"), count: budget / 2 + 1024)
    let older = directory.appendingPathComponent("nvst-20260101-000000.log")
    let newer = directory.appendingPathComponent("nvst-20260102-000000.log")
    try chunk.write(to: older)
    try chunk.write(to: newer)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)

    NvstDiagnosticLog.pruneLogsOverBudget(in: directory, budget: budget)

    #expect(FileManager.default.fileExists(atPath: newer.path))
    #expect(!FileManager.default.fileExists(atPath: older.path))
}
