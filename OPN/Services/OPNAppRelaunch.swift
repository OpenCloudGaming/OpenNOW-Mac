//  Restarts the app, for a setting that is only read once at launch.

import AppKit

@MainActor
enum OPNAppRelaunch {
    /// How long the helper waits for this process to exit before giving up, so a quit the reader
    /// cancels does not leave a relaunch pending forever.
    static let waitSeconds = 60

    /// The shell line that outlives this process: it waits for `pid` to go, then opens the bundle.
    /// The bundle path travels as an argument rather than inside the script text.
    static func helperArguments(pid: Int32) -> [String] {
        let script = "i=0; while kill -0 \(pid) 2>/dev/null && [ $i -lt \(waitSeconds * 5) ]; do sleep 0.2; i=$((i+1)); done; /usr/bin/open \"$0\""
        return ["-c", script, Bundle.main.bundlePath]
    }

    static func relaunch() {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = helperArguments(pid: ProcessInfo.processInfo.processIdentifier)
        do {
            try helper.run()
        } catch {
            OPNLog.warning(.app, "Relaunch helper could not start: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }
}
