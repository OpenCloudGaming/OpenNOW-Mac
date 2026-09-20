import AppKit
import SwiftUI

/// The status item's label: the OpenNOW cloud mark, and the queue position while there is one.
///
/// The game, the phase detail, and the elapsed clock live in the popover. The one thing the label
/// adds is the queue number — the state a user parked behind a seat most wants to see without
/// opening anything. The ETA stays out: it changes on every vendor poll, and driving the native
/// status-button renderer with text that changes that often is what this label avoids. A position
/// changes only when the seat advances, so the label stays quiet while a session runs.
struct OPNMenuBarStatusLabel: View {
    @ObservedObject var session: OPNMenuBarSessionModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: session.phase.symbolName)
            if let queueCountText = session.phase.menuBarQueueCountText {
                Text(queueCountText)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(session.accessibilityLabel())
    }
}

/// The menu bar scene's content: the panel, plus the popover-window follower.
///
/// The follower is deliberately outside `OPNMenuBarPanel` so the panel stays a pure SwiftUI view the
/// snapshot tests can render — `ImageRenderer` cannot rasterise an `NSViewRepresentable`, and a
/// representable inside the panel intermittently produced no image at all.
struct OPNMenuBarSceneContent: View {
    @ObservedObject var session: OPNMenuBarSessionModel

    var body: some View {
        OPNMenuBarPanel(session: session)
            .background {
                // `MenuBarExtra` gives no per-open callback, so the panel reports its own window and
                // the session model follows it: each open re-checks for a session started elsewhere.
                MenuBarPopoverWindowReader { session.observePopoverWindow($0) }
            }
    }
}

/// The popover's top-level views, switched by the icon tabs above the cards.
///
/// Two destinations and no more: the session surface the panel has always been, and the account's
/// favorites. Both are one tap away, so the compact icon row is all the affordance a popover this
/// size needs — no label under an icon that the accessibility label already carries.
enum OPNMenuBarTab: String, CaseIterable, Identifiable {
    case session
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: return "Session"
        case .favorites: return "Favorites"
        }
    }

    var symbolName: String {
        switch self {
        case .session: return "gamecontroller.fill"
        case .favorites: return "heart.fill"
        }
    }
}

/// The status item's popover.
///
/// `MenuBarExtra`'s `.window` style hands SwiftUI the whole panel, which is what lets the surface
/// read the way the Control Center popovers it is modelled on read: stacked tiles with their own
/// controls, instead of an AppKit menu of one-line items. The tiles are therefore rounded rather than
/// DESIGN.md's 1px-stroke rectangles — the documented exception this surface exists under — and on
/// macOS 26 and later the session controls among them are Liquid Glass. `OPNMenuBarCards` holds the
/// reasoning for which parts get the material.
struct OPNMenuBarPanel: View {
    @ObservedObject var session: OPNMenuBarSessionModel
    @Environment(\.openWindow) private var openWindow

    /// Wide enough for a game title beside its artwork, narrow enough to stay a popover.
    static let width: CGFloat = 316
    /// How many rows the Favorites list shows before it starts to scroll. The panel grows with the
    /// list up to this many, then holds the height — one tap of a favorite never resizes the popover
    /// past a comfortable size, and a longer list scrolls inside it.
    static let favoritesVisibleRows = 5
    /// One game row's height: the 34pt artwork with 5pt above and below it. Fixed so the Favorites
    /// list's height can be computed rather than measured.
    static let gameRowHeight: CGFloat = 44
    static let gameRowSpacing: CGFloat = 8

    @State private var selectedTab: OPNMenuBarTab

    init(session: OPNMenuBarSessionModel, initialTab: OPNMenuBarTab = .session) {
        self.session = session
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            tabBar
            // Fixed above the switch: who is signed in does not depend on which tab is showing, so
            // the account card stays put — and the account dropdown keeps its state — across a switch.
            OPNMenuBarAccountSection(session: session, onPresentMainWindow: openMainWindow)
            selectedTabContent
            footer
        }
        .padding(10)
        .frame(width: Self.width)
        .opnMenuBarPanelBackground()
    }

    @ViewBuilder private var selectedTabContent: some View {
        switch selectedTab {
        case .session:
            sessionCard
            continuePlayingCard
        case .favorites:
            favoritesCard
        }
    }

    // MARK: - Tabs

    /// The tabs are glass on macOS 26 and later, so the row is gathered into one
    /// `GlassEffectContainer` the same way the session controls are: one sampling region, and shapes
    /// that can interact rather than sample each other.
    @ViewBuilder private var tabBar: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) { tabTiles }
        } else {
            tabTiles
        }
    }

    private var tabTiles: some View {
        HStack(spacing: 6) {
            ForEach(OPNMenuBarTab.allCases) { tab in
                tabButton(tab)
            }
        }
    }

    private func tabButton(_ tab: OPNMenuBarTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            guard selectedTab != tab else { return }
            withAnimation(OPNDesign.Motion.toggle) { selectedTab = tab }
        } label: {
            Image(systemName: tab.symbolName)
                .font(.opnUI(size: 13, weight: .bold))
                .foregroundStyle(tabIconInk(isSelected: isSelected))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .opnMenuBarTab(isSelected: isSelected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The selected tab's glyph sits on an accent-tinted glass, where the ordinary text ink all but
    /// disappears. `OPNDesign.onAccent` is the ink designed to be read on an accent fill, so it keeps
    /// the mark legible whatever the accent preset. The older, untinted fill path has no tint to
    /// fight and keeps the primary ink.
    private func tabIconInk(isSelected: Bool) -> Color {
        guard isSelected else { return OPNDesign.Text.secondary }
        if #available(macOS 26.0, *) { return OPNDesign.onAccent }
        return OPNDesign.Text.primary
    }

    // MARK: - Session

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: session.phase.symbolName)
                    .font(.opnUI(size: 15, weight: .bold))
                    .foregroundStyle(session.hasActiveStream ? OPNDesign.accent : OPNDesign.Text.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    // A session this Mac can rejoin is named first, so Resume says what it resumes.
                    if let resumableTitle = session.resumableSessionTitle {
                        Text(resumableTitle)
                            .font(.opnUI(size: 14, weight: .bold))
                            .foregroundStyle(OPNDesign.Text.primary)
                            .lineLimit(1)
                        Text(OPNMenuBarReadout.resumableStatusText)
                            .font(.opnUI(size: 11.5, weight: .medium))
                            .foregroundStyle(OPNDesign.Text.secondary)
                            .lineLimit(1)
                    } else if let title = OPNMenuBarReadout.panelTitleText(session.gameTitle) {
                        // With no game to name, the status line is the card's headline rather than a
                        // subtitle under a redundant "OpenNOW".
                        Text(title)
                            .font(.opnUI(size: 14, weight: .bold))
                            .foregroundStyle(OPNDesign.Text.primary)
                            .lineLimit(1)
                        Text(session.panelStatusText())
                            .font(.opnUI(size: 11.5, weight: .medium))
                            .foregroundStyle(OPNDesign.Text.secondary)
                            .lineLimit(1)
                    } else {
                        Text(session.panelStatusText())
                            .font(.opnUI(size: 14, weight: .bold))
                            .foregroundStyle(OPNDesign.Text.primary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let elapsedText = session.streamElapsedText {
                    Text(verbatim: elapsedText)
                        .font(.opnUI(size: 13, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(OPNDesign.Text.primary)
                }
            }
            controlRow
        }
        .opnMenuBarCard()
    }

    /// The controls are the popover's glass elements, and a container is what Apple asks for when
    /// several glass shapes sit next to each other: one sampling region, and shapes that can interact
    /// rather than sample each other.
    @ViewBuilder private var controlRow: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { controlTiles }
        } else {
            controlTiles
        }
    }

    private var controlTiles: some View {
        HStack(spacing: 8) {
            controlTile("Resume", systemImage: "play.fill", isEnabled: session.canResumeSession) {
                session.resumeSession()
            }
            controlTile("Pause", systemImage: "pause.fill", isEnabled: session.hasActiveStream) {
                session.pauseSession()
            }
            controlTile("End", systemImage: "stop.fill", tint: OPNDesign.Semantic.destructive, isEnabled: session.hasActiveStream) {
                session.endSession()
            }
        }
    }

    private func controlTile(
        _ title: String,
        systemImage: String,
        tint: Color? = nil,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.opnUI(size: 14, weight: .bold))
                Text(title)
                    .font(.opnUI(size: 10.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isEnabled ? (tint ?? OPNDesign.Text.primary) : OPNDesign.Text.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .opnMenuBarControl()
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }

    // MARK: - Continue Playing

    private var continuePlayingCard: some View {
        VStack(alignment: .leading, spacing: Self.gameRowSpacing) {
            cardEyebrow("CONTINUE PLAYING")
            if session.recentGames.isEmpty {
                emptyListText("Games you play show up here.")
            } else {
                ForEach(session.recentGames) { game in
                    gameButton(game, isEnabled: session.canLaunchRecentGames)
                }
            }
        }
        .opnMenuBarCard()
    }

    // MARK: - Favorites

    private var favoritesCard: some View {
        VStack(alignment: .leading, spacing: Self.gameRowSpacing) {
            cardEyebrow("FAVORITES")
            if session.favorites.isEmpty {
                emptyListText("Games you favorite show up here.")
            } else {
                favoritesList
            }
        }
        .opnMenuBarCard()
    }

    /// The favorites list grows with its contents and only starts scrolling past
    /// `favoritesVisibleRows`: short lists keep the popover its natural size, a long one holds the
    /// same height and scrolls. Constraining a `ScrollView` to `maxHeight` would not do that — it is
    /// greedy and would take the cap even when the list is shorter — so the scroll view is only
    /// introduced once the rows outgrow the cap, at the height they occupy there.
    @ViewBuilder private var favoritesList: some View {
        if session.favorites.count > Self.favoritesVisibleRows {
            ScrollView(.vertical) {
                favoritesRows
            }
            .scrollIndicators(.visible)
            .frame(height: favoritesVisibleHeight)
        } else {
            favoritesRows
        }
    }

    private var favoritesRows: some View {
        VStack(alignment: .leading, spacing: Self.gameRowSpacing) {
            ForEach(session.favorites) { game in
                gameButton(game, isEnabled: session.canLaunchFavorites)
            }
        }
    }

    private var favoritesVisibleHeight: CGFloat {
        let rows = CGFloat(Self.favoritesVisibleRows)
        return rows * Self.gameRowHeight + (rows - 1) * Self.gameRowSpacing
    }

    private func cardEyebrow(_ text: String) -> some View {
        Text(text)
            .font(.opnUI(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(OPNDesign.Text.muted)
    }

    private func emptyListText(_ text: String) -> some View {
        Text(text)
            .font(.opnUI(size: 11.5, weight: .medium))
            .foregroundStyle(OPNDesign.Text.tertiary)
            .padding(.vertical, 2)
    }

    private func gameButton(_ game: OPNMenuBarGame, isEnabled: Bool) -> some View {
        Button { launch(game) } label: {
            gameRow(game, isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("Launch \(game.title)")
    }

    private func gameRow(_ game: OPNMenuBarGame, isEnabled: Bool) -> some View {
        HStack(spacing: 9) {
            OPNMenuBarArtwork(url: game.artworkURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(game.title)
                    .font(.opnUI(size: 12.5, weight: .semibold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
                // The card's header already says what the list is; repeating it under every title
                // says nothing. When the game was last played is what a Continue Playing row can add,
                // so a favorite — which has no timestamp — is a title-only row.
                if let lastPlayedText = OPNMenuBarReadout.lastPlayedText(for: game.lastPlayedAt) {
                    Text(lastPlayedText)
                        .font(.opnUI(size: 10.5, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "play.fill")
                .font(.opnUI(size: 10, weight: .bold))
                .foregroundStyle(isEnabled ? OPNDesign.accent : OPNDesign.Text.muted)
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.gameRowHeight)
        .opnMenuBarRow()
    }

    /// A game started here does not bring the window forward: a window on screen, in the Dock, or
    /// hidden by the close button all have their surface mounted, so the launch runs inside one of
    /// them and the window is left exactly where the user put it. Only a launch with no window at all
    /// — menu-bar-only startup — has to build one for the request to land in.
    ///
    /// On screen, not merely existing: a window the scene has never built has no surface to hand the
    /// launch to, and a launch handed to it would be parked with nothing to act on it.
    private func launch(_ game: OPNMenuBarGame) {
        if OPNMainWindow.needsPresentation {
            // A window is about to be built, so it comes with its Dock icon even though the launch
            // itself leaves it behind whatever the user is doing.
            OPNDockIconController.showDockIcon()
            openWindow(id: "main")
        }
        session.requestLaunch(game)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button { openMainWindow() } label: {
                footerLabel("OpenNOW", systemImage: "macwindow")
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button { session.quitApplication() } label: {
                footerLabel("Quit", systemImage: "power")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private func footerLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.opnUI(size: 11, weight: .bold))
            Text(title)
                .font(.opnUI(size: 12, weight: .semibold))
        }
        .foregroundStyle(OPNDesign.Text.secondary)
        .accessibilityLabel(title)
    }

    /// Raising the app as well as the window: a menu bar action leaves another application
    /// frontmost, and a window opened behind it looks like nothing happened. A window sitting in the
    /// Dock is brought back with its place kept, and one the close button hid is ordered front again;
    /// only a window the scene has never built is rebuilt by the scene above it.
    private func openMainWindow() {
        // The window comes back with its Dock icon: menu-bar-only mode is a trade made while hidden.
        OPNDockIconController.showDockIcon()
        openWindow(id: "main")
        OPNMainWindow.reveal()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// A recent game's box art, drawn from the catalog's own image cache so opening the popover never
/// re-downloads something the catalog already has.
private struct OPNMenuBarArtwork: View {
    let url: String?

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "gamecontroller.fill")
                    .font(.opnUI(size: 14, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.muted)
            }
        }
        .frame(width: 34, height: 34)
        .background(OPNDesign.Fill.neutral(0.08))
        // swiftlint:disable:next design_no_corner_radius -- status-item popover chrome: artwork tiles match the Control Center cards this surface is modelled on
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: url) { await load() }
    }

    private func load() async {
        // Cleared first: a row can be reused for another game, and a stale cover is worse than the
        // placeholder while the new one loads.
        image = nil
        guard let url, let parsed = URL(string: url) else { return }
        let cached = await CatalogImageCache.shared.image(for: parsed, maxPixelSize: 96)
        image = cached?.image
    }
}

/// Reports the window the status item's popover is hosted in, so the session model can follow it.
///
/// `MenuBarExtra` exposes no per-open callback, and the popover window is ordered in and out rather
/// than torn down, so `.onAppear` fires once. The hosted window is the reliable handle, and the
/// model owns the notification lifecycle.
private struct MenuBarPopoverWindowReader: NSViewRepresentable {
    let onWindowChanged: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> MenuBarPopoverWindowReaderView {
        let view = MenuBarPopoverWindowReaderView()
        view.onWindowChanged = onWindowChanged
        return view
    }

    func updateNSView(_ nsView: MenuBarPopoverWindowReaderView, context: Context) {
        nsView.onWindowChanged = onWindowChanged
    }
}

private final class MenuBarPopoverWindowReaderView: NSView {
    var onWindowChanged: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window)
    }
}
