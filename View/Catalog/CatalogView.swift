import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

enum CatalogVendorLayout {
    static var appBarBackground: Color { OPNDesign.Surface.appBar }
    static var mallSurface: Color { OPNDesign.Surface.app }
    static var tileTray: Color { OPNDesign.Surface.tileTray }
    /// Hover growth stops just short of the neighbouring tile's artwork: a tile is 352pt wide in a
    /// 368pt slot, so anything past 192/176 = 1.09 crosses into the tile beside it, which a rail
    /// cannot order around (a `LazyHStack` paints its children in index order and ignores `zIndex`).
    static let tileScaleFactor: CGFloat = 1.08
    static let heroAspectRatio: CGFloat = 0.3229
    static let detailPanelAspectRatio: CGFloat = 0.3229

    private static let baseWindowTopInset: CGFloat = 32
    private static let baseAppBarHeight: CGFloat = 56
    private static let baseSectionHeaderMargin: CGFloat = 40
    private static let baseCarouselContainerMargin: CGFloat = 32
    private static let baseTileHorizontalMargin: CGFloat = 8
    private static let baseTileTopMargin: CGFloat = 16
    private static let baseCardTrayHeight: CGFloat = 40
    private static let baseWideTileWidth: CGFloat = 352
    private static let baseWideTileHeight: CGFloat = 198
    private static let baseHeroFallbackHeight: CGFloat = 500
    private static let baseHeroMaxHeight: CGFloat = 760
    private static let baseDetailPanelMinHeight: CGFloat = 500
    private static let baseDetailPanelMaxHeight: CGFloat = 760
    private static let baseMainMenuWidth: CGFloat = 344
    private static let baseAccountMenuWidth: CGFloat = 260

    /// The window titlebar has a fixed physical height regardless of interface scale; chrome below
    /// it is positioned with the measured inset (WindowTopInsetReader) and falls back to this value.
    static var fallbackWindowTopInset: CGFloat { baseWindowTopInset }

    static func appBarHeight(scale: CGFloat) -> CGFloat { baseAppBarHeight * scale }
    static func sectionHeaderMargin(scale: CGFloat) -> CGFloat { baseSectionHeaderMargin * scale }
    static func carouselContainerMargin(scale: CGFloat) -> CGFloat { baseCarouselContainerMargin * scale }
    static func tileHorizontalMargin(scale: CGFloat) -> CGFloat { baseTileHorizontalMargin * scale }
    static func tileTopMargin(scale: CGFloat) -> CGFloat { baseTileTopMargin * scale }
    /// Matches the top margin, and exists because hover scales the tile about its centre: with the
    /// margin only above, a hovered tile grew ~13pt past the bottom of its own frame and closed the
    /// gap to the row below to a few points, while the top still looked right.
    static func tileBottomMargin(scale: CGFloat) -> CGFloat { baseTileTopMargin * scale }
    /// Height one tile claims in a rail, both margins included. Density scales the tile alone: the
    /// margins are Interface Scale's territory, so a denser page packs tiles closer without also
    /// shrinking the gutters around them.
    static func tileRowHeight(scale: CGFloat, density: CGFloat = 1.0) -> CGFloat {
        wideTileHeight(scale: scale, density: density) + tileTopMargin(scale: scale) + tileBottomMargin(scale: scale)
    }
    static func cardTrayHeight(scale: CGFloat) -> CGFloat { baseCardTrayHeight * scale }
    static func wideTileWidth(scale: CGFloat, density: CGFloat = 1.0) -> CGFloat { baseWideTileWidth * scale * density }
    static func wideTileHeight(scale: CGFloat, density: CGFloat = 1.0) -> CGFloat { baseWideTileHeight * scale * density }
    static func heroFallbackHeight(scale: CGFloat) -> CGFloat { baseHeroFallbackHeight * scale }
    static func heroMaxHeight(scale: CGFloat) -> CGFloat { baseHeroMaxHeight * scale }
    static func detailPanelMinHeight(scale: CGFloat) -> CGFloat { baseDetailPanelMinHeight * scale }
    static func detailPanelMaxHeight(scale: CGFloat) -> CGFloat { baseDetailPanelMaxHeight * scale }
    static func mainMenuWidth(scale: CGFloat) -> CGFloat { baseMainMenuWidth * scale }
    static func accountMenuWidth(scale: CGFloat) -> CGFloat { baseAccountMenuWidth * scale }

    /// Hero keeps its 0.3229 ratio as the window widens instead of stopping at 500pt, which made the
    /// banner artwork look squeezed on ultrawide/5K windows.
    static func heroHeight(for width: CGFloat, viewportHeight: CGFloat = 0, scale: CGFloat) -> CGFloat {
        let fallback = heroFallbackHeight(scale: scale)
        guard width > 0 else { return fallback }
        var maximum = heroMaxHeight(scale: scale)
        if viewportHeight > 0 {
            maximum = min(maximum, max(fallback, viewportHeight * 0.78))
        }
        return min(width * heroAspectRatio, maximum)
    }

    /// Detail panel height grows with the panel width so the artwork keeps a sane aspect ratio on
    /// ultrawide/5K windows instead of being squeezed into a fixed 500pt letterbox.
    static func detailPanelHeight(for width: CGFloat, viewportHeight: CGFloat = 0, scale: CGFloat) -> CGFloat {
        let minimum = detailPanelMinHeight(scale: scale)
        guard width > 0 else { return minimum }
        var maximum = detailPanelMaxHeight(scale: scale)
        if viewportHeight > 0 {
            maximum = min(maximum, max(minimum, viewportHeight * 0.78))
        }
        return OPNDesign.clamped(width * detailPanelAspectRatio, minimum: minimum, maximum: maximum)
    }

    static func heroImageLeading(for width: CGFloat) -> CGFloat {
        width > 0 ? OPNDesign.clamped(56 + width * 0.14, minimum: 120, maximum: 280) : 258
    }

    static func searchWidth(for width: CGFloat) -> CGFloat {
        OPNDesign.clamped(width * 0.46, minimum: 280, maximum: 640)
    }

    static func launchPanelWidth(for width: CGFloat) -> CGFloat {
        OPNDesign.clamped(width - 64, minimum: 360, maximum: 640)
    }

    static func heroTextLeading(for width: CGFloat) -> CGFloat {
        OPNDesign.clamped(width * 0.09, minimum: 42, maximum: 108)
    }

    static func heroTextWidth(for width: CGFloat) -> CGFloat {
        OPNDesign.clamped(width * 0.39, minimum: 320, maximum: 470)
    }
}

extension Font {
    static func catalogText(size: CGFloat, weight: OPNUIFont.Weight = .regular) -> Font {
        OPNUIFont.font(size: size, weight: weight)
    }
}

struct CatalogFontModifier: ViewModifier {
    @Environment(\.opnUIScale) private var uiScale
    let size: CGFloat
    let weight: OPNUIFont.Weight

    func body(content: Content) -> some View {
        content.font(OPNUIFont.font(size: size * uiScale, weight: weight))
    }
}

extension View {
    func catalogFont(size: CGFloat, weight: OPNUIFont.Weight = .regular) -> some View {
        modifier(CatalogFontModifier(size: size, weight: weight))
    }
}

struct CatalogView: View {
    let accounts: [LoginAccount]
    /// Listed accounts whose tokens are gone: switching to one needs a fresh sign-in.
    let signedOutAccountEmails: Set<String>
    let onSwitch: (LoginAccount) -> Void
    let onAddAccount: () -> Void
    let onSignOut: (LoginAccount) -> Void
    let onForget: (LoginAccount) -> Void
    let onRefreshAuth: () async -> Bool
    let onWindowTitleChange: (String?) -> Void

    @Binding private var pendingGameShortcut: GFNGameShortcut?

    @AppStorage(OPNInterfacePreferences.controllerModeEnabledKey) private var controllerModeEnabled = false
    @AppStorage(OPNInterfacePreferences.uiScaleKey) private var uiScale = OPNInterfacePreferences.defaultUIScale
    @AppStorage(OPNThemePreferences.tileDensityKey) private var tileDensityRawValue = OPNThemePreferences.TileDensity.comfortable.rawValue
    @AppStorage(OPNThemePreferences.accentColorKey) private var accentColorRawValue = OPNThemePreferences.AccentColor.cloudGreen.rawValue
    @AppStorage(OPNThemePreferences.appearanceKey) private var appearanceRawValue = OPNThemePreferences.Appearance.dark.rawValue
    @EnvironmentObject private var systemAppearance: OPNSystemAppearance
    @State private var viewModel: CatalogViewModel
    @State private var showsMainMenu = false
    @State private var showsAccountMenu = false
    /// The shared iCloud coordinator. Read in `body`, so a conflict a background pass detects
    /// reaches this page as an observation change and can raise the prompt below.
    private let cloudSync = OPNCloudSyncCoordinator.shared
    /// Categories already offered through the prompt. A waved-away conflict stays quiet for the
    /// session, while one that is resolved and later re-diverges is offered again.
    @State private var promptedSyncConflicts: Set<OPNCloudSyncCategory> = []
    @State private var isSyncConflictAlertPresented = false
    /// The theme the catalog page has actually been rebuilt for. It lags `themeIdentity` while
    /// Settings is open so picking a colour repaints Settings instantly without rebuilding every
    /// rail and tile behind it; the catalog catches up when the reader returns to it.
    @State private var appliedCatalogThemeIdentity = ""
    @State private var streamWindowTopInset: CGFloat = 0
    @State private var catalogWindowTopInset: CGFloat = 0

    private var measuredCatalogTopInset: CGFloat {
        catalogWindowTopInset > 0 ? catalogWindowTopInset : CatalogVendorLayout.fallbackWindowTopInset
    }

    private var isCatalogPageActive: Bool { viewModel.selectedMainPage == .games }

    /// Pending iCloud conflicts the reader has not already been shown a prompt for.
    private var unpromptedSyncConflicts: [OPNCloudSyncConflict] {
        cloudSync.pendingConflicts.filter { !promptedSyncConflicts.contains($0.category) }
    }

    /// The prompt belongs to the home page, so it stays off the settings page that owns the resolve
    /// controls and off a stream or an open launch flow it would otherwise cover.
    private var canPresentSyncConflictAlert: Bool {
        isCatalogPageActive
            && viewModel.activeStreamConfiguration == nil
            && !viewModel.isLaunchFlowVisible
            && !viewModel.isGameInfoVisible
    }

    private var syncConflictAlertTitle: String {
        let conflicts = cloudSync.pendingConflicts
        guard let first = conflicts.first else { return "Sync Conflict" }
        return conflicts.count == 1 ? "Sync Conflict — \(first.category.title)" : "\(conflicts.count) Sync Conflicts"
    }

    private var syncConflictAlertMessage: String {
        let conflicts = cloudSync.pendingConflicts
        guard let first = conflicts.first else {
            return "Open iCloud settings to choose which copy to keep."
        }
        guard conflicts.count == 1 else {
            let categories = conflicts.map { $0.category.title.lowercased() }.joined(separator: ", ")
            return "This Mac and the shared backup both changed your \(categories) since the last sync. Open iCloud settings to choose which copies to keep."
        }
        return "This Mac and \(first.remoteDisplayName) both changed your \(first.category.title.lowercased()) since the last sync. Open iCloud settings to choose which copy to keep."
    }

    /// Offers the prompt once per diverged category, and forgets a category that is no longer in
    /// conflict so a fresh divergence asks again.
    private func refreshSyncConflictAlert() {
        promptedSyncConflicts.formIntersection(Set(cloudSync.pendingConflicts.map(\.category)))
        guard !isSyncConflictAlertPresented, canPresentSyncConflictAlert else { return }
        let unprompted = unpromptedSyncConflicts
        guard !unprompted.isEmpty else { return }
        promptedSyncConflicts.formUnion(unprompted.map(\.category))
        isSyncConflictAlertPresented = true
    }

    /// Clears the prompt and lands the reader on the iCloud page, where a conflict card resolves it.
    private func openICloudSettingsFromSyncConflictAlert() {
        isSyncConflictAlertPresented = false
        viewModel.showSettings(.iCloud)
    }

    /// The saved accounts reduced to the menu bar's snapshot shape, so a change the view's SwiftData
    /// query reports — a rename, a new account, a sign-out — is something `onChange` can compare.
    private var menuBarAccountsSignature: [OPNMenuBarAccount] {
        accounts.map { account in
            OPNMenuBarAccount(
                email: account.email,
                displayName: account.displayName,
                membershipTier: account.membershipTier,
                isSignedOut: signedOutAccountEmails.contains(account.email),
                isActive: account.email == viewModel.account.email
            )
        }
    }

    private var tileDensity: CGFloat {
        (OPNThemePreferences.TileDensity(rawValue: tileDensityRawValue) ?? .comfortable).tileScale
    }

    private var accentColorPreset: OPNThemePreferences.AccentColor {
        OPNThemePreferences.AccentColor(rawValue: accentColorRawValue) ?? .cloudGreen
    }

    private var appearancePreference: OPNThemePreferences.Appearance {
        OPNThemePreferences.Appearance(rawValue: appearanceRawValue) ?? .dark
    }

    private var themeIdentity: String { "\(accentColorRawValue)-\(appearanceRawValue)-\(systemAppearance.isDark)" }

    /// Nil under Match System, so the window inherits whatever macOS is set to rather than pinning
    /// a scheme the palette would then have to agree with.
    private var preferredColorScheme: ColorScheme? {
        switch OPNThemePreferences.Appearance(rawValue: appearanceRawValue) ?? .dark {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }

    init(
        account: LoginAccount,
        session: LoginSession,
        accounts: [LoginAccount],
        signedOutAccountEmails: Set<String>,
        pendingGameShortcut: Binding<GFNGameShortcut?>,
        onSwitch: @escaping (LoginAccount) -> Void,
        onAddAccount: @escaping () -> Void,
        onSignOut: @escaping (LoginAccount) -> Void,
        onForget: @escaping (LoginAccount) -> Void,
        onRefreshAuth: @escaping () async -> Bool,
        onWindowTitleChange: @escaping (String?) -> Void
    ) {
        self.accounts = accounts
        self.signedOutAccountEmails = signedOutAccountEmails
        self.onSwitch = onSwitch
        self.onAddAccount = onAddAccount
        self.onSignOut = onSignOut
        self.onForget = onForget
        self.onRefreshAuth = onRefreshAuth
        self.onWindowTitleChange = onWindowTitleChange
        _pendingGameShortcut = pendingGameShortcut
        _viewModel = State(initialValue: CatalogViewModel(account: account, session: session, onSwitchAccount: onSwitch, onAddAccount: onAddAccount, onRefreshAuth: onRefreshAuth))
    }

    var body: some View {
        // Same reason as `ContentView`: the panes keyed on `themeIdentity` rebuild inside this body
        // pass, so the palette has to be resolved before they draw rather than in an `onChange`.
        let _ = OPNDesign.applyTheme(accent: accentColorPreset, appearance: appearancePreference, systemColorScheme: systemAppearance.colorScheme)
        ZStack {
            if let streamConfiguration = viewModel.activeStreamConfiguration {
                GeometryReader { proxy in
                    StreamStageLayout(
                        viewport: proxy.size,
                        topInset: streamWindowTopInset,
                        aspectRatio: CGFloat(viewModel.streamProfile.aspectRatio)
                    ) { _ in
                        StreamHostView(
                            configuration: streamConfiguration,
                            onProgress: { progress in viewModel.updateActiveStreamProgress(progress) },
                            onRequiredSessionAd: { ad in
                                try await viewModel.presentRequiredStreamAd(ad)
                            },
                            onEnd: { success, message, report in
                                viewModel.finishActiveStream(success: success, message: message, report: report)
                            }
                        )
                        .id(streamConfiguration.id)
                    }
                }
                .background(WindowTopInsetReader { streamWindowTopInset = $0 })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .transition(.opacity)
            } else {
                ZStack {
                    if controllerModeEnabled {
                        ControllerCatalogView(viewModel: viewModel, accounts: accounts, signedOutAccountEmails: signedOutAccountEmails, topInset: measuredCatalogTopInset, onSwitch: onSwitch, onAddAccount: onAddAccount, onSignOut: onSignOut, onForget: onForget)
                            .transition(.opacity)
                    } else {
                        VStack(spacing: 0) {
                            CatalogTopBar(viewModel: viewModel, showsMainMenu: $showsMainMenu, showsAccountMenu: $showsAccountMenu, onSwitch: onSwitch, onSignOut: onSignOut, onForget: onForget)
                                .id(themeIdentity)
                                // The bar's tooltips hang below its bounds, so it must outdraw the
                                // content below it; the zIndexed overlays still cover it when open.
                                .zIndex(1)
                            ZStack {
                                // The catalog stays mounted underneath Settings and Recordings
                                // rather than being swapped out for them. Tearing it down drops
                                // every rail, every tile and the decoded artwork each tile holds
                                // in its own state, so coming back rebuilt and re-decoded the
                                // whole page - a second or more of pinned CPU on a plain page
                                // switch. Hidden, it costs a layout it has already done.
                                CatalogContentView(viewModel: viewModel, isActive: isCatalogPageActive)
                                    .id(appliedCatalogThemeIdentity)
                                    .opacity(isCatalogPageActive ? 1 : 0)
                                    .disabled(!isCatalogPageActive)
                                    .accessibilityHidden(!isCatalogPageActive)
                                if viewModel.selectedMainPage == .settings {
                                    SettingsView(viewModel: viewModel)
                                        .id(themeIdentity)
                                } else if viewModel.selectedMainPage == .screenshots {
                                    ScreenshotsView()
                                        .id(themeIdentity)
                                } else if viewModel.selectedMainPage == .recordings {
                                    RecordingsView()
                                        .id(themeIdentity)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .padding(.top, measuredCatalogTopInset)
                        .transition(.opacity)

                        // Both menus stay mounted and animate themselves in and out. Wrapping them
                        // in an `if` here removed them before their exit transition could run, and
                        // gave the scrim and the panel one shared transition instead of two.
                        CatalogMainMenuOverlay(viewModel: viewModel, isPresented: $showsMainMenu, topInset: measuredCatalogTopInset)
                            .zIndex(12)

                        CatalogAccountDropdownOverlay(viewModel: viewModel, accounts: accounts, signedOutAccountEmails: signedOutAccountEmails, isPresented: $showsAccountMenu, topInset: measuredCatalogTopInset, onSwitch: onSwitch, onAddAccount: onAddAccount, onSignOut: onSignOut, onForget: onForget)
                            .zIndex(13)
                    }
                    if viewModel.isLaunchFlowVisible {
                        VendorLaunchFlowOverlay(viewModel: viewModel)
                            .transition(.opacity)
                            .zIndex(20)
                    }

                    if viewModel.isGameInfoVisible {
                        CatalogGameInfoOverlay(viewModel: viewModel, topInset: measuredCatalogTopInset)
                            .transition(.opacity)
                            .zIndex(17)
                    }

                    if viewModel.isStorePickerVisible {
                        CatalogStorePickerOverlay(viewModel: viewModel, topInset: measuredCatalogTopInset)
                            .transition(.opacity)
                            .zIndex(18)
                    }

                    if viewModel.isDiagnosticsUploadConfirmationVisible {
                        DiagnosticsUploadConfirmationDialog(
                            cancel: { viewModel.cancelDiagnosticsUpload() },
                            upload: { viewModel.confirmDiagnosticsUpload() },
                            uiScale: uiScale
                        )
                        .transition(.opacity)
                        .zIndex(19)
                    }

                    if let insights = viewModel.sessionInsights {
                        SessionInsightsOverlay(
                            insights: insights,
                            uiScale: uiScale,
                            dismiss: { isOptingOut in viewModel.dismissSessionInsights(isOptingOut: isOptingOut) }
                        )
                        .transition(.opacity)
                        .zIndex(22)
                    }

                    if viewModel.isCollectionsPickerPresented {
                        CatalogCollectionsPickerOverlay(viewModel: viewModel)
                            .transition(.opacity)
                            .zIndex(24)
                    }

                    if viewModel.isCollectionsManagerPresented {
                        CatalogCollectionsManagerOverlay(viewModel: viewModel, close: { viewModel.dismissCollectionsManager() })
                            .transition(.opacity)
                            .zIndex(24)
                    }

                    if viewModel.collectionsDialog != nil {
                        CatalogCollectionsDialogOverlay(viewModel: viewModel)
                            .transition(.opacity)
                            .zIndex(25)
                    }

                    if viewModel.isCollectionsIconPickerPresented {
                        CatalogCollectionIconPickerOverlay(viewModel: viewModel)
                            .transition(.opacity)
                            .zIndex(27)
                    }

                    if viewModel.isCollectionsNoticePresented {
                        CatalogCollectionsNoticeOverlay(viewModel: viewModel)
                            .transition(.opacity)
                            .zIndex(26)
                    }
                }
                .background {
                    // Mounted only while a collections surface is up: a permanently installed
                    // monitor would eat Escape from whatever else owns it on the page.
                    if viewModel.hasPresentedCollectionsOverlay {
                        CatalogCollectionsEscapeMonitor { viewModel.dismissTopmostCollectionsOverlay() }
                    }
                }
                .background(WindowTopInsetReader { catalogWindowTopInset = $0 })
                .environment(\.opnUIScale, uiScale)
                .environment(\.opnTileDensity, tileDensity)
            }

            if viewModel.isStreamLaunchLoadingVisible {
                VendorStreamLaunchLoadingOverlay(viewModel: viewModel, windowTopInset: measuredCatalogTopInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .zIndex(10)
                    .ignoresSafeArea()
            }
        }
        .ignoresSafeArea(edges: .all)
        .background(OPNDesign.Surface.app)
        .background(StreamWindowAspectConfigurator(aspectRatio: viewModel.streamProfile.aspectRatio, isLocked: viewModel.activeStreamConfiguration != nil))
        .task { @MainActor in
            viewModel.start()
            viewModel.loadIfNeeded()
            consumePendingGameShortcut()
            updateWindowTitleForActiveStream()
            // Bound for as long as this window is on screen: the menu bar surface follows the
            // launch flow through it, and can hand a launch back to it while it exists.
            viewModel.attachMenuBarSurface()
        }
        // Reported from the view rather than from the fetch callbacks: the point of the signal is
        // that a frame carrying real content has been built, not that bytes arrived.
        .task(id: viewModel.hasStartupContent) { @MainActor in
            guard let gate = viewModel.startupContentGate else { return }
            StartupReadiness.shared.markContentReady(gate: gate)
        }
        .onChange(of: pendingGameShortcut) { @MainActor _, _ in consumePendingGameShortcut() }
        .onChange(of: menuBarAccountsSignature, initial: true) { @MainActor _, _ in
            viewModel.updateMenuBarAccounts(accounts, signedOutAccountEmails: signedOutAccountEmails)
        }
        .onChange(of: viewModel.activeStreamConfiguration) { @MainActor _, _ in
            updateWindowTitleForActiveStream()
            refreshSyncConflictAlert()
        }
        .onChange(of: themeIdentity, initial: true) { @MainActor _, newIdentity in
            guard isCatalogPageActive else { return }
            appliedCatalogThemeIdentity = newIdentity
        }
        .onChange(of: viewModel.selectedMainPage) { @MainActor _, _ in
            guard isCatalogPageActive else { return }
            appliedCatalogThemeIdentity = themeIdentity
            refreshSyncConflictAlert()
        }
        .onChange(of: cloudSync.pendingConflicts) { @MainActor _, _ in refreshSyncConflictAlert() }
        .onAppear { @MainActor in refreshSyncConflictAlert() }
        .onDisappear { @MainActor in
            viewModel.detachMenuBarSurface()
            onWindowTitleChange(nil)
        }
        .opnConfirmation(
            isPresented: $isSyncConflictAlertPresented,
            eyebrow: "ICLOUD SYNC",
            title: syncConflictAlertTitle,
            message: syncConflictAlertMessage,
            actions: [
                OPNConfirmationAction("NOT NOW", role: .cancel) { isSyncConflictAlertPresented = false },
                OPNConfirmationAction("OPEN SETTINGS") { openICloudSettingsFromSyncConflictAlert() }
            ]
        )
        .preferredColorScheme(preferredColorScheme)
    }

    private func updateWindowTitleForActiveStream() {
        guard let configuration = viewModel.activeStreamConfiguration else {
            onWindowTitleChange(nil)
            return
        }
        let title = configuration.title.trimmingCharacters(in: .whitespacesAndNewlines)
        onWindowTitleChange(title.isEmpty ? "GeForce NOW" : title)
    }

    private func consumePendingGameShortcut() {
        guard let shortcut = pendingGameShortcut else { return }
        OPNLog.info(.shortcut, "CatalogView consuming pending shortcut cmsId=\(shortcut.cmsId) shortName=\(shortcut.shortName) title=\(shortcut.lookupTitle)")
        pendingGameShortcut = nil
        viewModel.openGameShortcut(shortcut)
    }
}

/// Escape handling for the collections surfaces. `onExitCommand` fires only for the focused view,
/// and these panels never take keyboard focus, so the press reached whatever was focused behind
/// them and the manager sat unresponsive. The monitor is mounted only while a surface is up and
/// consumes nothing but Escape, so the dialog and picker fields keep every other key.
private struct CatalogCollectionsEscapeMonitor: NSViewRepresentable {
    /// Called for Escape while a collections surface is up. Main-actor by construction: a local key
    /// monitor is delivered on the main thread. Returns whether it closed a surface.
    let handle: @MainActor @Sendable () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.box.handle = handle
        context.coordinator.installMonitor()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.box.handle = handle
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        let box = CatalogCollectionsEscapeHandlerBox()
        private var monitor: Any?

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [box] event in
                guard event.keyCode == 53 else { return event }
                let window = event.window
                let handled = MainActor.assumeIsolated {
                    // A sheet outranks a panel behind it: while one is up, Escape belongs to the sheet.
                    guard window?.sheetParent == nil,
                          window?.attachedSheet == nil else { return false }
                    return box.handle()
                }
                return handled ? nil : event
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// Holds the monitor's key handler for its closure. The closure has to be Sendable, and the handler
/// it calls is main-actor state, so the box — not the coordinator — is what the closure captures.
/// Local key monitors are delivered on the main thread, which is what makes the hop safe.
private final class CatalogCollectionsEscapeHandlerBox: @unchecked Sendable {
    var handle: @MainActor @Sendable () -> Bool = { false }
}
