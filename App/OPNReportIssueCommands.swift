import SwiftUI

struct OPNReportIssueCommands: Commands {
    @FocusedValue(\.opnReportIssuePresentation) private var presentation

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button {
                (presentation ?? .shared).present(context: .appEnvironment())
            } label: {
                Label("Report an Issue…", systemImage: "exclamationmark.bubble")
            }
        }
    }
}
