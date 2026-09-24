//  Standalone runner for the benchmarks that used to live inside the test suite.
//
//  The audits measure things tests deliberately do not assert on and ship their numbers as JSON
//  on stdout. `relay-conversion` also gates two regression thresholds; a breach prints a FAIL
//  verdict and exits nonzero so CI can still notice it without the suite carrying timed asserts.

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

        var failures = 0
        for command in commands where requested == "all" || command.name == requested {
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

    private static func printUsage(_ commands: [(name: String, summary: String, run: () throws -> Bool)]) {
        print("usage: swift run OpenNOWBenchmarks <command>")
        print()
        for command in commands {
            print("  \(command.name)  \(command.summary)")
        }
        print("  all          run every benchmark")
    }
}
