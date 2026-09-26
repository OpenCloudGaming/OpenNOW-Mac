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
    /// Windows that are leaving full screen before they can be torn down. Held strongly: the whole
    /// point is that the window outlives the dismissal until its exit lands.
    private var windowsLeavingFullScreen: [ObjectIdentifier: OPNStreamWindow] = [:]

    /// Whether a stream window is on screen. Read by the catalog so a surface that belongs to the
    /// session (the iCloud conflict prompt) keeps out of the way.
    var isPresented: Bool { window != nil }

    /// Brings the stream window forward. The catalog's running-session banner and the Dock's own
    /// affordances both mean "show me the game" when they are clicked, and a PiP window comes back
    /// as itself rather than being restored first.
    func focus() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

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
        // A launch is not a "show me" action. `OPNMainWindow.present(activating:)` sets the rule the
        // whole app follows - a session launch leaves the app where it is, and the Session Ready
        // preference keeps the only say over whether OpenNOW comes forward - and an unconditional
        // `makeKeyAndOrderFront` here broke it: the app activated the moment the stream window was
        // created, so `OPNSessionReadyAction.sessionDidBecomeReady`'s `guard !isActive` short-
        // circuited and its Off and Notification choices became dead code for any launch.
        switch Self.launchPresentation(isAppActive: NSApp.isActive) {
        case .takeKey: window.makeKeyAndOrderFront(nil)
        case .orderFrontWithoutActivating: window.orderFront(nil)
        }
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
        // A full-screen window cannot be ordered out directly. It lives in a Space of its own, and
        // ordering it out while it is still full screen leaves that Space behind showing black,
        // forever - there is no window left to close it. The exit has to land first; see
        // `exitFullScreenBeforeDismissing`.
        guard Self.needsFullScreenExitBeforeDismissing(styleMask: window.styleMask) else {
            tearDownWindow(window)
            return
        }
        exitFullScreenBeforeDismissing(window)
    }

    /// Whether a window has to leave full screen before it can be ordered out.
    ///
    /// Pure, so the trap that ships a black screen stays assertable without a window server: a
    /// full-screen window is in its own Space, and ordering it out there leaves the Space black
    /// with no window left to close it.
    static func needsFullScreenExitBeforeDismissing(styleMask: NSWindow.StyleMask) -> Bool {
        styleMask.contains(.fullScreen)
    }

    /// Leaves full screen, then tears down once the exit has landed.
    ///
    /// The window is kept alive until the exit lands - releasing it on the way out would leave the
    /// Space it is animating out of just as stuck. A cancelled launch and a rebind both land here
    /// for the same window, so the second call is a no-op rather than a second toggle.
    private func exitFullScreenBeforeDismissing(_ window: OPNStreamWindow) {
        let id = ObjectIdentifier(window)
        guard windowsLeavingFullScreen[id] == nil else { return }
        windowsLeavingFullScreen[id] = window
        window.toggleFullScreen(nil)
        // Polled rather than observed, the same way `StreamWindowGeometryGate` waits out a nested
        // run loop: the exit is animated and AppKit has no single notification that means "the
        // Space is back", and a missed one would leave the teardown hanging with a window nobody
        // can close. The cap is the exit's own worst case; a window that refuses to leave is
        // ordered out anyway rather than kept forever.
        Task { @MainActor [weak self] in
            var remainingAttempts = 200
            while window.styleMask.contains(.fullScreen), remainingAttempts > 0 {
                remainingAttempts -= 1
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.finishDismissing(window)
        }
    }

    private func finishDismissing(_ window: OPNStreamWindow) {
        windowsLeavingFullScreen.removeValue(forKey: ObjectIdentifier(window))
        tearDownWindow(window)
    }

    /// Clearing the content is what runs the stream surface's `.onDisappear` teardown; ordering out
    /// alone would leave a session behind a window nobody can see.
    private func tearDownWindow(_ window: OPNStreamWindow) {
        window.stopPersistingFrame()
        window.orderOut(nil)
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
        let decision = Self.closeDecision(isConnected: surface?.isConnected, hasActiveStream: StreamSessionLifecycle.hasActiveStream)
        if case .prompt = decision {
            presentClosePrompt(for: surface)
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

    /// Raises the stream controls panel. With no reachable surface the panel is raised through the
    /// registry every other out-of-window surface uses - same panel, same three answers.
    private func presentClosePrompt(for surface: (any OPNStreamWindowSessionSurface)?) {
        guard let surface else {
            _ = StreamSessionLifecycle.sendCommand(.showQuitMenu)
            return
        }
        surface.showStreamControls(completion: nil)
    }

    /// What the close button does. Pure, so the contract - always prompts when there is a session,
    /// never shows a dialog when there is not - is asserted without building a window.
    /// `nil` is "no stream surface is hosting this window yet".
    /// How a *launching* stream window is ordered front.
    ///
    /// `takeKey` when OpenNOW is already frontmost: the window has to become key or the game gets no
    /// input, and taking key from our own window costs nobody their focus. `orderFrontWithoutActivating`
    /// when it is not, which is the case the Session Ready preference exists for - appearing behind
    /// whatever the user moved to, and coming forward only if they asked it to.
    ///
    /// Distinct from `focus()`, which is a real "show me" action and always activates.
    enum LaunchPresentation: Equatable {
        case takeKey
        case orderFrontWithoutActivating
    }

    static func launchPresentation(isAppActive: Bool) -> LaunchPresentation {
        isAppActive ? .takeKey : .orderFrontWithoutActivating
    }

    enum CloseDecision: Equatable {
        /// Raise the existing stream controls panel and leave the window where it is.
        case prompt
        /// Cancel the launch and close the window; no dialog, because there is no session.
        case cancelLaunchAndDismiss
    }

    /// `isConnected` is `nil` when the window cannot name its surface at all.
    ///
    /// That case never silently cancels: if a stream is live anywhere, it prompts. Losing the
    /// reference is the failure that shipped once - `NSWindow.delegate` is weak, the guard died,
    /// and the close button ended a running session with no dialog - and the answer to "I cannot
    /// tell whether there is a session" must never be "end it". Only a session that answers `false`
    /// itself, or no session at all, takes the quiet path.
    static func closeDecision(isConnected: Bool?, hasActiveStream: Bool) -> CloseDecision {
        switch isConnected {
        case true: return .prompt
        case false: return .cancelLaunchAndDismiss
        case nil: return hasActiveStream ? .prompt : .cancelLaunchAndDismiss
        }
    }

    private static func windowTitle(for configuration: StreamLaunchConfiguration) -> String {
        let title = configuration.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "GeForce NOW" : title
    }
}
