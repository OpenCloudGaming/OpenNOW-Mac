import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

enum CatalogVendorLayout {
    static let appBarBackground = OpenNOWDesign.Surface.appBar
    static let mallSurface = OpenNOWDesign.Surface.app
    static let tileTray = OpenNOWDesign.Surface.tileTray
    static let tileScaleFactor: CGFloat = 1.12
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
    /// Height one tile claims in a rail, both margins included.
    static func tileRowHeight(scale: CGFloat) -> CGFloat {
        wideTileHeight(scale: scale) + tileTopMargin(scale: scale) + tileBottomMargin(scale: scale)
    }
    static func cardTrayHeight(scale: CGFloat) -> CGFloat { baseCardTrayHeight * scale }
    static func wideTileWidth(scale: CGFloat) -> CGFloat { baseWideTileWidth * scale }
    static func wideTileHeight(scale: CGFloat) -> CGFloat { baseWideTileHeight * scale }
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
        return OpenNOWDesign.clamped(width * detailPanelAspectRatio, minimum: minimum, maximum: maximum)
    }

    static func heroImageLeading(for width: CGFloat) -> CGFloat {
        width > 0 ? OpenNOWDesign.clamped(56 + width * 0.14, minimum: 120, maximum: 280) : 258
    }

    static func searchWidth(for width: CGFloat) -> CGFloat {
        OpenNOWDesign.clamped(width * 0.46, minimum: 280, maximum: 640)
    }

    static func launchPanelWidth(for width: CGFloat) -> CGFloat {
        OpenNOWDesign.clamped(width - 64, minimum: 360, maximum: 640)
    }

    static func heroTextLeading(for width: CGFloat) -> CGFloat {
        OpenNOWDesign.clamped(width * 0.09, minimum: 42, maximum: 108)
    }

    static func heroTextWidth(for width: CGFloat) -> CGFloat {
        OpenNOWDesign.clamped(width * 0.39, minimum: 320, maximum: 470)
    }
}

extension Font {
    static func nvidia(size: CGFloat, weight: OpenNOWNVIDIAFont.Weight = .regular) -> Font {
        OpenNOWNVIDIAFont.font(size: size, weight: weight)
    }
}

struct NvidiaFontModifier: ViewModifier {
    @Environment(\.opnUIScale) private var uiScale
    let size: CGFloat
    let weight: OpenNOWNVIDIAFont.Weight

    func body(content: Content) -> some View {
        content.font(OpenNOWNVIDIAFont.font(size: size * uiScale, weight: weight))
    }
}

extension View {
    func nvidiaFont(size: CGFloat, weight: OpenNOWNVIDIAFont.Weight = .regular) -> some View {
        modifier(NvidiaFontModifier(size: size, weight: weight))
    }
}

struct CatalogView: View {
    let accounts: [LoginAccount]
    /// Listed accounts whose tokens are gone: switching to one needs a fresh sign-in.
    let signedOutAccountEmails: Set<String>
    let onSwitch: (LoginAccount) -> Void
    let onAddAccount: () -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void
    let onRefreshAuth: () async -> Bool
    let onWindowTitleChange: (String?) -> Void

    @Binding private var pendingGameShortcut: GFNGameShortcut?

    @AppStorage(OpenNOWInterfacePreferences.controllerModeEnabledKey) private var controllerModeEnabled = false
    @AppStorage(OpenNOWInterfacePreferences.uiScaleKey) private var uiScale = OpenNOWInterfacePreferences.defaultUIScale
    @State private var viewModel: CatalogViewModel
    @State private var showsMainMenu = false
    @State private var showsAccountMenu = false
    @State private var streamWindowTopInset: CGFloat = 0
    @State private var catalogWindowTopInset: CGFloat = 0

    private var measuredCatalogTopInset: CGFloat {
        catalogWindowTopInset > 0 ? catalogWindowTopInset : CatalogVendorLayout.fallbackWindowTopInset
    }

    private var isCatalogPageActive: Bool { viewModel.selectedMainPage == .games }

    init(
        account: LoginAccount,
        session: LoginSession,
        accounts: [LoginAccount],
        signedOutAccountEmails: Set<String>,
        pendingGameShortcut: Binding<GFNGameShortcut?>,
        onSwitch: @escaping (LoginAccount) -> Void,
        onAddAccount: @escaping () -> Void,
        onSignOut: @escaping () -> Void,
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
        _viewModel = State(initialValue: CatalogViewModel(account: account, session: session, onRefreshAuth: onRefreshAuth))
    }

    var body: some View {
        ZStack {
            if let streamConfiguration = viewModel.activeStreamConfiguration {
                GeometryReader { proxy in
                    let topInset = min(max(streamWindowTopInset, 0), proxy.size.height)
                    let contentHeight = max(proxy.size.height - topInset, 0)
                    let streamSize = streamContentSize(availableWidth: proxy.size.width, availableHeight: contentHeight, topInset: topInset)
                    VStack(spacing: 0) {
                        WebRTCMediaStreamView(
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
                        .frame(width: streamSize.width, height: streamSize.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(Color.black)
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
                            ZStack {
                                // The catalog stays mounted underneath Settings and Recordings
                                // rather than being swapped out for them. Tearing it down drops
                                // every rail, every tile and the decoded artwork each tile holds
                                // in its own state, so coming back rebuilt and re-decoded the
                                // whole page - a second or more of pinned CPU on a plain page
                                // switch. Hidden, it costs a layout it has already done.
                                CatalogContentView(viewModel: viewModel, isActive: isCatalogPageActive)
                                    .opacity(isCatalogPageActive ? 1 : 0)
                                    .disabled(!isCatalogPageActive)
                                    .accessibilityHidden(!isCatalogPageActive)
                                if viewModel.selectedMainPage == .settings {
                                    SettingsView(viewModel: viewModel)
                                } else if viewModel.selectedMainPage == .recordings {
                                    RecordingsView()
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .padding(.top, measuredCatalogTopInset)
                        .transition(.opacity)

                        // Both menus stay mounted and animate themselves in and out. Wrapping them
                        // in an `if` here removed them before their exit transition could run, and
                        // gave the scrim and the panel one shared transition instead of two.
                        CatalogMainMenuOverlay(viewModel: viewModel, isPresented: $showsMainMenu, topInset: measuredCatalogTopInset, onSignOut: onSignOut)
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
                }
                .background(WindowTopInsetReader { catalogWindowTopInset = $0 })
                .environment(\.opnUIScale, uiScale)
            }

            if viewModel.isStreamLaunchLoadingVisible {
                VendorStreamLaunchLoadingOverlay(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .zIndex(10)
                    .ignoresSafeArea()
            }
        }
        .ignoresSafeArea(edges: .all)
        .background(OpenNOWDesign.Surface.app)
        .background(StreamWindowAspectConfigurator(aspectRatio: viewModel.streamProfile.aspectRatio, isLocked: viewModel.activeStreamConfiguration != nil))
        .task { @MainActor in
            viewModel.start()
            viewModel.loadIfNeeded()
            consumePendingGameShortcut()
            updateWindowTitleForActiveStream()
        }
        .onChange(of: pendingGameShortcut) { @MainActor _, _ in consumePendingGameShortcut() }
        .onChange(of: viewModel.activeStreamConfiguration) { @MainActor _, _ in updateWindowTitleForActiveStream() }
        .onDisappear { @MainActor in onWindowTitleChange(nil) }
        .preferredColorScheme(.dark)
    }

    func streamContentSize(availableWidth: CGFloat, availableHeight: CGFloat, topInset: CGFloat) -> CGSize {
        guard topInset > 0, availableWidth > 0, availableHeight > 0 else {
            return CGSize(width: availableWidth, height: availableHeight)
        }
        let aspectRatio = CGFloat(viewModel.streamProfile.aspectRatio)
        guard aspectRatio.isFinite, aspectRatio > 0 else {
            return CGSize(width: availableWidth, height: availableHeight)
        }
        let heightForFullWidth = availableWidth / aspectRatio
        if heightForFullWidth <= availableHeight {
            return CGSize(width: availableWidth, height: heightForFullWidth)
        }
        return CGSize(width: availableHeight * aspectRatio, height: availableHeight)
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
        OpenNOWLog.info(.shortcut, "CatalogView consuming pending shortcut cmsId=\(shortcut.cmsId) shortName=\(shortcut.shortName) title=\(shortcut.lookupTitle)")
        pendingGameShortcut = nil
        viewModel.openGameShortcut(shortcut)
    }
}
