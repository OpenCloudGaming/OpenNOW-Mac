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

    /// Per-window full-screen bookkeeping, tracked from `present` so a dismissal that lands
    /// mid-enter is recognised before AppKit sets `.fullScreen`.
    @MainActor
    private final class WindowPresentation {
        let window: OPNStreamWindow
        var transition: FullScreenTransition = .none
        var observerTokens: [NSObjectProtocol] = []
        var isDismissalPending = false
        var isFullScreenExitRequested = false
        var backstopTask: Task<Void, Never>?

        var dismissalStep: DismissalStep {
            OPNStreamWindowPresenter.dismissalStep(
                transition: transition,
                styleMask: window.styleMask,
                isFullScreenExitRequested: isFullScreenExitRequested
            )
        }

        init(window: OPNStreamWindow) {
            self.window = window
        }
    }

    /// Which full-screen transition a window is in the middle of, if any.
    enum FullScreenTransition: Equatable {
        case none
        case entering
        case exiting
    }

    /// What a pending dismissal does next. Pure, so the race is assertable without a window server.
    enum DismissalStep: Equatable {
        case tearDownNow
        case waitForTransitionEnd
        case requestFullScreenExit
        case waitForExitToLand
    }

    /// Held strongly: a window must outlive its dismissal until the exit lands.
    private var presentations: [ObjectIdentifier: WindowPresentation] = [:]

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
        // Tracked for the window's whole life so a mid-enter dismissal sees the transition.
        track(window)
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

    /// Decides whether this window can go out now or has to wait for a full-screen transition.
    private func dismissWindow(_ window: OPNStreamWindow) {
        let presentation = presentations[ObjectIdentifier(window)] ?? track(window)
        guard presentation.dismissalStep != .tearDownNow else {
            finishDismissing(window)
            return
        }
        presentation.isDismissalPending = true
        if presentation.backstopTask == nil {
            startBackstopTask(for: presentation)
        }
        advanceDismissal(presentation)
    }

    /// Carries a pending dismissal one step further, from the dismissal itself and from every
    /// full-screen transition notification.
    private func advanceDismissal(_ presentation: WindowPresentation) {
        guard presentation.isDismissalPending else { return }
        switch presentation.dismissalStep {
        case .tearDownNow:
            finishDismissing(presentation.window)
        case .requestFullScreenExit:
            presentation.isFullScreenExitRequested = true
            presentation.window.toggleFullScreen(nil)
        case .waitForExitToLand, .waitForTransitionEnd:
            break
        }
    }

    /// Backstop for a `did…` notification that never arrives; the cap is the exit's worst case.
    private func startBackstopTask(for presentation: WindowPresentation) {
        presentation.backstopTask = Task { @MainActor [weak self] in
            for _ in 0..<200 {
                guard !Task.isCancelled else { return }
                guard presentation.dismissalStep != .tearDownNow else {
                    self?.finishDismissing(presentation.window)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.finishDismissing(presentation.window)
        }
    }

    /// The landing gate: an exit has landed only once the transition is over **and** `.fullScreen`
    /// is clear. Waiting on the mask alone tears the window down mid-animation.
    static func dismissalStep(
        transition: FullScreenTransition,
        styleMask: NSWindow.StyleMask,
        isFullScreenExitRequested: Bool
    ) -> DismissalStep {
        switch transition {
        case .entering:
            return .waitForTransitionEnd
        case .exiting:
            return .waitForExitToLand
        case .none:
            break
        }
        guard needsFullScreenExitBeforeDismissing(styleMask: styleMask) else { return .tearDownNow }
        return isFullScreenExitRequested ? .waitForExitToLand : .requestFullScreenExit
    }

    /// Whether a window has to leave full screen before it can be ordered out.
    ///
    /// Pure, so the trap that ships a black screen stays assertable without a window server: a
    /// full-screen window is in its own Space, and ordering it out there leaves the Space black
    /// with no window left to close it.
    static func needsFullScreenExitBeforeDismissing(styleMask: NSWindow.StyleMask) -> Bool {
        styleMask.contains(.fullScreen)
    }

    /// Observers live on the `WindowPresentation`, never on the presenter, so two windows at once
    /// route to the right one.
    @discardableResult
    private func track(_ window: OPNStreamWindow) -> WindowPresentation {
        let presentation = WindowPresentation(window: window)
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
            // Deferred one turn so the Space collapse's re-presentation lands before teardown.
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.endTransition(.exiting, for: id)
            }
        }
        presentation.observerTokens = [willEnter, didEnter, willExit, didExit]
        presentations[id] = presentation
        return presentation
    }

    private func setTransition(_ transition: FullScreenTransition, for id: ObjectIdentifier) {
        presentations[id]?.transition = transition
    }

    private func endTransition(_ transition: FullScreenTransition, for id: ObjectIdentifier) {
        guard let presentation = presentations[id] else { return }
        guard presentation.transition == transition else { return }
        presentation.transition = .none
        advanceDismissal(presentation)
    }

    private func removeTransitionObservers(from presentation: WindowPresentation) {
        let center = NotificationCenter.default
        for token in presentation.observerTokens { center.removeObserver(token) }
        presentation.observerTokens = []
    }

    private func finishDismissing(_ window: OPNStreamWindow) {
        if let presentation = presentations.removeValue(forKey: ObjectIdentifier(window)) {
            presentation.backstopTask?.cancel()
            removeTransitionObservers(from: presentation)
        }
        tearDownWindow(window)
    }

    /// Clearing the content is what runs the stream surface's `.onDisappear` teardown.
    private func tearDownWindow(_ window: OPNStreamWindow) {
        window.stopPersistingFrame()
        window.orderOut(nil)
        window.contentView = nil
        // A late re-presentation must not leave the contentless window on screen.
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
