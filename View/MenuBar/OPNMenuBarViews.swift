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

/// The popover's top-level views, switched by the icon tabs above the cards: the session surface,
/// the account's favorites, and the account's collections, all one tap away.
enum OPNMenuBarTab: String, CaseIterable, Identifiable {
    case session
    case favorites
    case collections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: return "Session"
        case .favorites: return "Favorites"
        case .collections: return "Collections"
        }
    }

    var symbolName: String {
        switch self {
        case .session: return "gamecontroller.fill"
        case .favorites: return "heart.fill"
        case .collections: return OPNCollectionIcon.defaultSymbolName
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

    @State private var selectedTab: OPNMenuBarTab
    /// The collection the Collections tab has open, if any. Held by the panel rather than the card, so
    /// switching tabs and back returns to the collection that was open.
    @State private var selectedCollectionId: String?

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
        case .collections:
            OPNMenuBarCollectionsCard(session: session, selectedCollectionId: $selectedCollectionId, onLaunchGame: launch)
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
        VStack(alignment: .leading, spacing: OPNMenuBarListMetrics.rowSpacing) {
            OPNMenuBarEyebrow(text: "CONTINUE PLAYING")
            if session.recentGames.isEmpty {
                OPNMenuBarEmptyText(text: "Games you play show up here.")
            } else {
                ForEach(session.recentGames) { game in
                    OPNMenuBarGameButton(game: game, isEnabled: session.canLaunchRecentGames) { launch(game) }
                }
            }
        }
        .opnMenuBarCard()
    }

    // MARK: - Favorites

    private var favoritesCard: some View {
        VStack(alignment: .leading, spacing: OPNMenuBarListMetrics.rowSpacing) {
            OPNMenuBarEyebrow(text: "FAVORITES")
            if session.favorites.isEmpty {
                OPNMenuBarEmptyText(text: "Games you favorite show up here.")
            } else {
                OPNMenuBarCappedList(rowCount: session.favorites.count) {
                    VStack(alignment: .leading, spacing: OPNMenuBarListMetrics.rowSpacing) {
                        ForEach(session.favorites) { game in
                            OPNMenuBarGameButton(game: game, isEnabled: session.canLaunchFavorites) { launch(game) }
                        }
                    }
                }
            }
        }
        .opnMenuBarCard()
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
