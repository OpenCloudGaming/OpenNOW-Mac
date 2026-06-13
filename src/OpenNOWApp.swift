import AppKit

import Backend
import SwiftUI

@main
struct OpenNOWApp: App {
    @NSApplicationDelegateAdaptor(OPNAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            OpenNOWSettingsScenePlaceholder()
        }
    }
}

private struct OpenNOWSettingsScenePlaceholder: View {
    var body: some View {
        Text("OpenNOW settings are managed in the main window during migration.")
            .padding(24)
            .frame(minWidth: 360)
    }
}
