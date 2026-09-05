//  App-root orchestration: the one-shot bootstrap, the startup animation's lifetime, the window
//  title, and the file-open plumbing that arrives either through `onOpenURL` or through a
//  notification posted by the app delegate.
//
//  Extracted from `ContentView`, which held all of it as `@State` and subscribed to
//  `NotificationCenter` from inside `body`. A notification observer whose lifetime is a view's
//  render is exactly the shape that leaks, so it lives here with an explicit bind/unbind.
//

import Combine
import Foundation

@MainActor
final class AppRootViewModel: ObservableObject {
    static let defaultWindowTitle = "OpenNOW"

    @Published var windowTitle = AppRootViewModel.defaultWindowTitle
    @Published var isShowingStartupLoading = true
    @Published private(set) var usesQuickStartupIntro = false

    private var didBootstrap = false
    private var login: LoginViewModel?
    private var fileOpenObserver: AnyCancellable?

    var startupAnimationDuration: Double {
        usesQuickStartupIntro ? OpenNOWStartupAnimation.quickDuration : OpenNOWStartupAnimation.duration
    }

    func bind(login: LoginViewModel) {
        self.login = login
        guard fileOpenObserver == nil else { return }
        fileOpenObserver = NotificationCenter.default
            .publisher(for: .openNOWDidOpenFile)
            .compactMap { $0.object as? URL }
            .sink { [weak self] url in
                self?.login?.handleOpenedFile(url)
            }
    }

    func unbind() {
        fileOpenObserver = nil
        login = nil
    }

    func setWindowTitle(_ title: String?) {
        windowTitle = title ?? Self.defaultWindowTitle
    }

    /// Runs once per app launch. `syncModelState` is supplied by the view because the data it feeds
    /// in comes from live `@Query` results, which only the view can read.
    ///
    /// `login` is a parameter rather than something this expects `bind` to have already supplied.
    /// SwiftUI starts a `.task` *before* it calls `onAppear`, so binding there and bootstrapping
    /// here raced: on a lost race `login` was nil, the whole bootstrap silently no-opped, and
    /// `didBootstrap` had already latched - so it never ran again and the app came up with no
    /// session restored and no opened files drained.
    func bootstrapIfNeeded(login: LoginViewModel, syncModelState: () -> Void) async {
        bind(login: login)
        guard !didBootstrap else { return }
        didBootstrap = true
        syncModelState()
        login.bootstrap()
        drainOpenedFiles()
        usesQuickStartupIntro = login.activeSession != nil
        await dismissStartupLoading()
    }

    private func dismissStartupLoading() async {
        let delay = usesQuickStartupIntro
            ? OpenNOWStartupAnimation.quickDismissalDelayNanoseconds
            : OpenNOWStartupAnimation.dismissalDelayNanoseconds
        do {
            try await Task.sleep(nanoseconds: delay)
        } catch {
            isShowingStartupLoading = false
            return
        }
        // The fade itself is the view's: it animates on this value rather than being wrapped in a
        // `withAnimation` here, which is what kept SwiftUI out of this file.
        isShowingStartupLoading = false
    }

    private func drainOpenedFiles() {
        for url in OpenNOWFileOpenCoordinator.shared.drainPendingFileURLs() {
            login?.handleOpenedFile(url)
        }
    }

    func handleOpenURL(_ url: URL) {
        // SwiftUI delivers a document opened while the app is running (Finder, `open -a`) here as a
        // file URL, not through the AppKit `application(openFile:)` delegate; a `.gfnpc` shortcut
        // arriving this way used to be treated as an OAuth callback and dropped.
        if url.isFileURL {
            OpenNOWLog.info(.shortcut, "onOpenURL received file: \(url.path)")
            login?.handleOpenedFile(url)
            return
        }
        login?.handleOAuthCallback(url)
    }
}
