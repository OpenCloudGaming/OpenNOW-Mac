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

    /// The presenter's bookkeeping for a window it put on screen.
    ///
    /// Full-screen state is tracked from `present` until teardown rather than only once a dismissal
    /// starts: a stream ended *mid-enter* has to be recognised as transitioning even though AppKit
    /// has not set `.fullScreen` yet, and there is no API that answers "is a full-screen transition
    /// in flight".
    private final class PresentedWindow {
        let window: OPNStreamWindow
        var transition: FullScreenTransition = .none
        var transitionObserverTokens: [NSObjectProtocol] = []
        /// Set once `dismiss()` has decided the window cannot go out until its exit lands. Its
        /// presence is what makes the transition notifications below finish the teardown instead of
        /// merely updating `transition`.
        var pendingDismissal: PendingDismissal?

        init(window: OPNStreamWindow) {
            self.window = window
        }

        final class PendingDismissal {
            /// Set once `toggleFullScreen` has been asked to leave. Keeps a second `dismiss()` from
            /// toggling twice for the same window.
            var hasRequestedFullScreenExit = false
            var pollTask: Task<Void, Never>?
        }
    }

    /// Which full-screen transition a window is in the middle of, if any.
    enum FullScreenTransition: Equatable {
        case none
        case entering
        case exiting
    }

    /// What a pending dismissal does next, given what its window is doing right now. Pure, so the
    /// race stays assertable without a window server.
    enum DismissalStep: Equatable {
        /// Nothing stands in the way: order the window out and clear its content.
        case tearDownNow
        /// A transition is in flight and no exit has to be asked for yet; wait for it to land.
        case waitForTransitionEnd
        /// The window is full screen and has not been asked to leave: toggle it out.
        case requestFullScreenExit
        /// An exit is in flight (or already requested); wait for it to land.
        case waitForExitToLand
    }

    /// Windows the presenter is tracking, held strongly: the whole point is that a window outlives
    /// its dismissal until its exit lands.
    private var presentedWindows: [ObjectIdentifier: PresentedWindow] = [:]

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
        // Track full-screen state for the window's whole life, so a dismissal that lands mid-enter
        // still knows the transition is in flight. See `PresentedWindow`.
        _ = track(window)
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
        dismissWindow(window)
    }

    /// Decides whether this window can go out now, or has to wait for a full-screen transition to
    /// land first.
    private func dismissWindow(_ window: OPNStreamWindow) {
        // A window presented by us is tracked from `present`; tracking lazily keeps the decision
        // correct for one that was not (and installs the backstop observers either way).
        let presented = presentedWindows[ObjectIdentifier(window)] ?? track(window)
        let step = Self.dismissalStep(
            transition: presented.transition,
            styleMask: window.styleMask,
            hasRequestedFullScreenExit: presented.pendingDismissal?.hasRequestedFullScreenExit ?? false
        )
        guard step != .tearDownNow else {
            finishDismissing(window)
            return
        }
        if presented.pendingDismissal == nil {
            presented.pendingDismissal = PresentedWindow.PendingDismissal()
            startBackstopPoll(for: presented)
        }
        advanceDismissal(presented)
    }

    /// Carries a pending dismissal one step further for the window's current state. Called when the
    /// dismissal starts and again from every full-screen transition notification.
    private func advanceDismissal(_ presented: PresentedWindow) {
        guard let pending = presented.pendingDismissal else { return }
        let window = presented.window
        switch Self.dismissalStep(
            transition: presented.transition,
            styleMask: window.styleMask,
            hasRequestedFullScreenExit: pending.hasRequestedFullScreenExit
        ) {
        case .tearDownNow:
            finishDismissing(window)
        case .requestFullScreenExit:
            pending.hasRequestedFullScreenExit = true
            window.toggleFullScreen(nil)
        case .waitForExitToLand, .waitForTransitionEnd:
            break
        }
    }

    /// The backstop for the notification path: a transition that never posts its `did…`
    /// notification would otherwise leave the dismissal hanging with a window nobody can close. The
    /// cap is the exit's own worst case; a window that refuses to leave is ordered out anyway rather
    /// than kept forever.
    private func startBackstopPoll(for presented: PresentedWindow) {
        presented.pendingDismissal?.pollTask = Task { @MainActor [weak self] in
            var remainingAttempts = 200
            while !Task.isCancelled {
                if Self.hasLandedFullScreenExit(
                    transition: presented.transition,
                    styleMask: presented.window.styleMask
                ) {
                    self?.finishDismissing(presented.window)
                    return
                }
                guard remainingAttempts > 0 else {
                    self?.finishDismissing(presented.window)
                    return
                }
                remainingAttempts -= 1
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// The gate the whole race turns on: the exit has landed only once the tracked transition is
    /// over **and** AppKit has cleared `.fullScreen`.
    ///
    /// The mask alone is the trap - AppKit clears it as the transition begins, before the window
    /// server collapses the Space and re-places the window on the desktop, so a teardown keyed to the
    /// mask lands mid-animation and leaves the empty window behind. Pure, so that stays assertable
    /// without a window server.
    static func hasLandedFullScreenExit(transition: FullScreenTransition, styleMask: NSWindow.StyleMask) -> Bool {
        transition == .none && !styleMask.contains(.fullScreen)
    }

    /// What a pending dismissal does next. See `DismissalStep`.
    static func dismissalStep(
        transition: FullScreenTransition,
        styleMask: NSWindow.StyleMask,
        hasRequestedFullScreenExit: Bool
    ) -> DismissalStep {
        switch transition {
        case .entering:
            // `.fullScreen` is not set yet, so waiting on the mask would tear the window down
            // mid-enter. Wait for `didEnter`, then decide again.
            return .waitForTransitionEnd
        case .exiting:
            // The mask can already be clear while the Space is still collapsing; the exit has not
            // landed until `didExit`.
            return .waitForExitToLand
        case .none:
            break
        }
        guard needsFullScreenExitBeforeDismissing(styleMask: styleMask) else { return .tearDownNow }
        return hasRequestedFullScreenExit ? .waitForExitToLand : .requestFullScreenExit
    }

    /// Whether a window has to leave full screen before it can be ordered out.
    ///
    /// Pure, so the trap that ships a black screen stays assertable without a window server: a
    /// full-screen window is in its own Space, and ordering it out there leaves the Space black
    /// with no window left to close it.
    static func needsFullScreenExitBeforeDismissing(styleMask: NSWindow.StyleMask) -> Bool {
        styleMask.contains(.fullScreen)
    }

    /// Starts tracking a window's full-screen transitions. Observers are held by the window's
    /// `PresentedWindow`, not by the presenter, so two windows at once route to the right one.
    private func track(_ window: OPNStreamWindow) -> PresentedWindow {
        let presented = PresentedWindow(window: window)
        let center = NotificationCenter.default
        let id = ObjectIdentifier(window)
        let willEnter = center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setTransition(.entering, for: id) }
        }
        let didEnter = center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endTransition(.entering, for: id) }
        }
        let willExit = center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setTransition(.exiting, for: id) }
        }
        let didExit = center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            // One main-actor turn on purpose: AppKit clears `.fullScreen` before the exit's final
            // re-presentation on the desktop, and that re-presentation is what survived as an empty
            // window. Deferring lets it land before the teardown can run.
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.endTransition(.exiting, for: id)
            }
        }
        presented.transitionObserverTokens = [willEnter, didEnter, willExit, didExit]
        presentedWindows[id] = presented
        return presented
    }

    private func setTransition(_ transition: FullScreenTransition, for id: ObjectIdentifier) {
        presentedWindows[id]?.transition = transition
    }

    private func endTransition(_ transition: FullScreenTransition, for id: ObjectIdentifier) {
        guard let presented = presentedWindows[id] else { return }
        if presented.transition == transition { presented.transition = .none }
        guard presented.pendingDismissal != nil else { return }
        advanceDismissal(presented)
    }

    private func removeTransitionObservers(from presented: PresentedWindow) {
        let center = NotificationCenter.default
        for token in presented.transitionObserverTokens { center.removeObserver(token) }
        presented.transitionObserverTokens = []
    }

    private func finishDismissing(_ window: OPNStreamWindow) {
        if let presented = presentedWindows.removeValue(forKey: ObjectIdentifier(window)) {
            presented.pendingDismissal?.pollTask?.cancel()
            removeTransitionObservers(from: presented)
        }
        tearDownWindow(window)
    }

    /// Clearing the content is what runs the stream surface's `.onDisappear` teardown; ordering out
    /// alone would leave a session behind a window nobody can see.
    private func tearDownWindow(_ window: OPNStreamWindow) {
        window.stopPersistingFrame()
        window.orderOut(nil)
        window.contentView = nil
        // Belt and braces: if a late full-screen re-presentation still puts the now-contentless
        // window back on screen, order it out again one main-actor turn later.
        Task { @MainActor [weak window] in
            guard let window, window.isVisible else { return }
            window.orderOut(nil)
        }
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
