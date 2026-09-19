#if DEBUG
import SwiftUI

/// The update-preview menus, in their own `Commands` value rather than written out inside
/// `OPNApp.body`.
///
/// Dev-only menus are the largest thing in that body — a `Menu` over a `TupleView` of four
/// `Button<Text>`s, twice — and the scene body is re-entered while SwiftUI flushes the scene graph.
/// Keeping them in their own value keeps the shipping scene small, and keeps the preview code
/// out of the file that defines the app's scenes.
struct OPNUpdatePreviewCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Menu("Preview Update Dialog") {
                Button("Update Available") {
                    OPNUpdatePresentation.shared.presentSampleUpdate()
                }
                Button("Up To Date") {
                    OPNUpdatePresentation.shared.presentSampleStatus(.upToDate(version: SettingsAppMetadata.version))
                }
                Button("Check Failed") {
                    OPNUpdatePresentation.shared.presentSampleStatus(.checkFailed(message: "The Internet connection appears to be offline."))
                }
                Button("Install Failed") {
                    OPNUpdatePresentation.shared.presentSampleStatus(.installFailed(message: "The downloaded app bundle did not pass macOS code-signature verification."))
                }
            }
            Menu("Preview Button Status") {
                Button(buttonStatusItemName("CHECKING…", matches: .checking)) {
                    OPNUpdatePresentation.shared.previewButtonStatus(.checking)
                }
                Button(buttonStatusItemName("JUST CHECKED", matches: .lastChecked(Date()))) {
                    OPNUpdatePresentation.shared.previewButtonStatus(.lastChecked(Date()))
                }
                Button(buttonStatusItemName("NEVER CHECKED", matches: .neverChecked)) {
                    OPNUpdatePresentation.shared.previewButtonStatus(.neverChecked)
                }
                Divider()
                Button(buttonStatusItemName("LIVE BEHAVIOR", matches: nil)) {
                    OPNUpdatePresentation.shared.previewButtonStatus(nil)
                }
            }
        }
    }

    /// Labels a Preview Button Status item with a leading checkmark when it is the currently active
    /// preview, so picking one gives visible feedback. Matching ignores the `lastChecked` date, since
    /// each press stores a fresh `Date()`.
    private func buttonStatusItemName(_ name: String, matches target: OPNUpdatePresentation.ButtonStatusPreview?) -> String {
        guard let preview = OPNUpdatePresentation.shared.buttonStatusPreview else {
            return target == nil ? "✓ \(name)" : name
        }
        let isActive: Bool
        switch (preview, target) {
        case (.checking, .some(.checking)),
             (.lastChecked, .some(.lastChecked)),
             (.neverChecked, .some(.neverChecked)):
            isActive = true
        default:
            isActive = false
        }
        return isActive ? "✓ \(name)" : name
    }
}

#endif
