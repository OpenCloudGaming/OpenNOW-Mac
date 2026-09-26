//  Who owns the dedicated stream window.
//
//  One window, one session. `present` is idempotent for the configuration it already holds, so the
//  catalog rebuilding behind the stream (a theme change, a page switch) cannot re-create the hosting
//  view and tear the session down; `dismiss` releases the window, so the next launch gets a freshly
//  configured one. Nothing here ever re-parents or reuses a hosting view across sessions.
//
//  Presentation is driven by the catalog window (`CatalogView`), which owns the launch state, while
//  the session itself lives in the stream window's content. The catalog window stays mounted
//  throughout - that is what lets its own menus and pages keep working mid-session, and what retires
//  the rebuild-and-re-decode cost swapping the stream in used to pay.
//

import AppKit
import SwiftUI

@MainActor
final class OPNStreamWindowPresenter {
    static let shared = OPNStreamWindowPresenter()

    private(set) var window: OPNStreamWindow?
    private var presentedConfigurationID: UUID?
    private var hostingView: NSHostingView<OPNStreamWindowRootView>?

    /// Whether a stream window is on screen. Read by the catalog so a surface that belongs to the
    /// session (the iCloud conflict prompt) keeps out of the way.
    var isPresented: Bool { window != nil }

    func present(configuration: StreamLaunchConfiguration, viewModel: CatalogViewModel) {
        if presentedConfigurationID == configuration.id, let window, window.isVisible { return }
        dismiss()

        let window = OPNStreamWindowFactory.make()
        let hostingView = NSHostingView(rootView: OPNStreamWindowRootView(configuration: configuration, viewModel: viewModel))
        window.contentView = hostingView
        // The game's title belongs to the window the game is in; the catalog window keeps its own.
        window.title = Self.windowTitle(for: configuration)
        // The close button always asks. See `OPNStreamWindowCloseGuard` for why the window never
        // closes itself, and `requestStreamWindowClose` for what each answer does.
        window.closeRequestHandler = { [weak self, weak viewModel, weak window] in
            self?.handleCloseRequest(viewModel: viewModel, window: window) ?? false
        }
        OPNStreamWindowCloseGuard.install(on: window)

        self.window = window
        self.hostingView = hostingView
        presentedConfigurationID = configuration.id
        window.makeKeyAndOrderFront(nil)
        OPNLog.info(.launch, "Stream window presented for \(configuration.applicationID)")
    }

    func dismiss() {
        guard let window else { return }
        // A close button or a cancellation can both land here for the same ending; the second call
        // has nothing left to do.
        presentedConfigurationID = nil
        hostingView = nil
        self.window = nil
        OPNStreamWindowCloseGuard.uninstall(from: window)
        window.closeRequestHandler = nil
        window.sessionSurface = nil
        window.orderOut(nil)
        // Ordering out is not enough on its own: the hosting view has to go for the stream surface's
        // `.onDisappear` teardown to run, and that is the difference between a session that ends and
        // one that keeps a window nobody can see.
        window.contentView = nil
    }

    /// The stream window's close button.
    ///
    /// A live session raises the existing stream controls panel - `showStreamControls()` with **no**
    /// completion, which is what keeps its third button reading "End Stream" rather than "Quit
    /// OpenNOW" - and refuses the close, so nothing happens until the user chooses. The panel's three
    /// answers then put the window where the choice says: Resume leaves it open, Pause and End tear
    /// the session down, and the teardown clears `activeStreamConfiguration`, which dismisses this
    /// window through the catalog's own observation.
    ///
    /// Before a session exists there is nothing to prompt about. `showStreamControls` already
    /// cancels a pending start and answers `completion?(true)` with no dialog on that path, and with
    /// a `nil` completion that answer is a no-op rather than a quit - so the launch is cancelled here
    /// instead, and the window closes.
    private func handleCloseRequest(viewModel: CatalogViewModel?, window: OPNStreamWindow?) -> Bool {
        let surface = window?.sessionSurface
        if case .prompt = Self.closeDecision(isConnected: surface?.isConnected) {
            surface?.showStreamControls(completion: nil)
            return true
        }
        // Nothing to prompt about: the pending start is cancelled through the same not-connected
        // path `showStreamControls` already had, and the launch itself is cancelled so the window
        // has nothing left to show.
        surface?.showStreamControls(completion: nil)
        // Deferred by one main-actor turn on purpose, the same way the main window's guard defers
        // its `orderOut`: tearing a window's content down from inside `windowShouldClose` runs the
        // teardown underneath AppKit's own close handling.
        Task { @MainActor [weak self, weak viewModel] in
            viewModel?.cancelActiveStreamLaunch()
            self?.dismiss()
        }
        return false
    }

    /// What the close button does. Pure, so the contract - always prompts when there is a session,
    /// never shows a dialog when there is not - is asserted without building a window.
    /// `nil` is "no stream surface is hosting this window yet".
    enum CloseDecision: Equatable {
        /// Raise the existing stream controls panel and leave the window where it is.
        case prompt
        /// Cancel the launch and close the window; no dialog, because there is no session.
        case cancelLaunchAndDismiss
    }

    static func closeDecision(isConnected: Bool?) -> CloseDecision {
        isConnected == true ? .prompt : .cancelLaunchAndDismiss
    }

    private static func windowTitle(for configuration: StreamLaunchConfiguration) -> String {
        let title = configuration.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "GeForce NOW" : title
    }
}
