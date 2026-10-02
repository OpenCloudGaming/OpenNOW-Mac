import Foundation
import Testing
@testable import OpenNOW

/// Sentry is gone (NEC-47), and with it the "Disable Telemetry" preference that used to gate these
/// paths: a fatal line and a telemetry event were dropped outright when it was on. The diagnostics
/// file is the one artefact a host can hand to a developer, so it is written for every run, and the
/// only level that stays opt-in is the high-volume debug one a developer asks for.
@Suite("Local diagnostics policy")
struct OPNDiagnosticsPolicyTests {
    @Test("every level a shipped build writes reaches the diagnostics file")
    func everyNonDebugLevelIsRecorded() {
        #expect(OPNDiagnostics.recordsLocally(.info))
        #expect(OPNDiagnostics.recordsLocally(.warning))
        #expect(OPNDiagnostics.recordsLocally(.error))
        #expect(OPNDiagnostics.recordsLocally(.fatal))
    }

    /// The key is retired: nothing reads it any more. This pins that a leftover value — either way —
    /// cannot switch local logging off, which is what the acceptance criteria for NEC-47 ask for.
    @Test("a leftover telemetry preference cannot gate local logging")
    func retiredTelemetryPreferenceDoesNotGateLocalLogging() {
        let key = "OpenNOW.Telemetry.Disabled"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        for disabled in [true, false] {
            UserDefaults.standard.set(disabled, forKey: key)
            #expect(OPNDiagnostics.recordsLocally(.info), "info with telemetry disabled=\(disabled)")
            #expect(OPNDiagnostics.recordsLocally(.warning), "warning with telemetry disabled=\(disabled)")
            #expect(OPNDiagnostics.recordsLocally(.error), "error with telemetry disabled=\(disabled)")
            #expect(OPNDiagnostics.recordsLocally(.fatal), "fatal with telemetry disabled=\(disabled)")
        }
    }

    @Test("debug output stays a developer opt-in")
    func debugStaysDeveloperOptIn() {
        #expect(OPNDiagnostics.recordsLocally(.debug) == OPNDiagnostics.shouldLogDebug())
    }
}
