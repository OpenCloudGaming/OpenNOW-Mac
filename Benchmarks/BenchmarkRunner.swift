//  Standalone runner for the benchmarks that used to live inside the test suite.
//
//  The audits measure things tests deliberately do not assert on and ship their numbers as JSON
//  on stdout. `relay-conversion` also gates two regression thresholds; a breach prints a FAIL
//  verdict and exits nonzero so CI can still notice it without the suite carrying timed asserts.
//
//  `OPENNOW_PERF_AUDIT_OUTPUT` names the report file. A single-command run writes that exact path;
//  `all` writes one file per audit instead (`benchmarks.json` becomes `benchmarks-catalog.json` and
//  `benchmarks-stream-preferences.json`), because one path shared by several audits in one process
//  would keep only the last report.

import Foundation

@main
struct OpenNOWBenchmarksRunner {
    static func main() {
        let commands: [(name: String, summary: String, run: () throws -> Bool)] = [
            ("catalog", "catalog decode/encode and view-model derivations at 96-3000 games", runCatalogPerformanceAudit),
            ("stream-preferences", "stream preference loading and effective-profile resolution", runStreamPreferencesPerformanceAudit)
        ]

        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            printUsage(commands)
            exit(2)
        }

        let requested = arguments[1]
        guard requested == "all" || commands.contains(where: { $0.name == requested }) else {
            print("unknown benchmark '\(requested)'")
            printUsage(commands)
            exit(2)
        }

        var perAuditOutputPath: String?
        if requested == "all",
           let path = ProcessInfo.processInfo.environment["OPENNOW_PERF_AUDIT_OUTPUT"],
           !path.isEmpty {
            perAuditOutputPath = path
        }

        var failures = 0
        for command in commands where requested == "all" || command.name == requested {
            if let perAuditOutputPath {
                _ = setenv("OPENNOW_PERF_AUDIT_OUTPUT", auditOutputPath(perAuditOutputPath, for: command.name), 1)
            }
            print("== \(command.name): \(command.summary) ==")
            do {
                if try !command.run() {
                    failures += 1
                }
            } catch {
                failures += 1
                print("error: \(error)")
            }
            print()
        }

        exit(failures == 0 ? 0 : 1)
    }

    /// `benchmarks.json` becomes `benchmarks-catalog.json`, so that audits sharing one process each
    /// write their own report. Derived from the path the caller gave, never from the current value of
    /// the variable, so one audit's path cannot become the next audit's base.
    private static func auditOutputPath(_ path: String, for command: String) -> String {
        let url = URL(fileURLWithPath: path)
        let fileExtension = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        let name = "\(url.deletingPathExtension().lastPathComponent)-\(command)\(fileExtension)"
        return url.deletingLastPathComponent().appendingPathComponent(name).path
    }

    private static func printUsage(_ commands: [(name: String, summary: String, run: () throws -> Bool)]) {
        print("usage: swift run OpenNOWBenchmarks <command>")
        print()
        for command in commands {
            print("  \(command.name)  \(command.summary)")
        }
        print("  all          run every benchmark")
    }
}
