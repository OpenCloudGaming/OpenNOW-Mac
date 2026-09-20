import AppKit
import SwiftUI

/// The status item's label: the OpenNOW cloud mark, and nothing else.
///
/// The game, the phase detail, and the elapsed clock live in the popover. Keeping the label to the
/// mark alone means the status item never resizes while a session runs, which is also what keeps the
/// native status-button renderer from being driven by per-second text updates.
struct OPNMenuBarStatusLabel: View {
    @ObservedObject var session: OPNMenuBarSessionModel

    var body: some View {
        Image(systemName: session.phase.symbolName)
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

    var body: some View {
        cards
            .padding(10)
            .frame(width: Self.width)
            .opnMenuBarPanelBackground()
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 10) {
            sessionCard
            continuePlayingCard
            footer
        }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("CONTINUE PLAYING")
                .font(.opnUI(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(OPNDesign.Text.muted)
            if session.recentGames.isEmpty {
                Text("Games you play show up here.")
                    .font(.opnUI(size: 11.5, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .padding(.vertical, 2)
            } else {
                ForEach(session.recentGames) { game in
                    Button { launch(game) } label: {
                        recentGameRow(game)
                    }
                    .buttonStyle(.plain)
                    .disabled(!session.canLaunchRecentGames)
                    .accessibilityLabel("Launch \(game.title)")
                }
            }
        }
        .opnMenuBarCard()
    }

    private func recentGameRow(_ game: OPNMenuBarRecentGame) -> some View {
        HStack(spacing: 9) {
            OPNMenuBarArtwork(url: game.artworkURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(game.title)
                    .font(.opnUI(size: 12.5, weight: .semibold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
                Text("Continue playing")
                    .font(.opnUI(size: 10.5, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
            }
            Spacer(minLength: 6)
            Image(systemName: "play.fill")
                .font(.opnUI(size: 10, weight: .bold))
                .foregroundStyle(session.canLaunchRecentGames ? OPNDesign.accent : OPNDesign.Text.muted)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opnMenuBarRow()
    }

    /// A game started here does not bring the window forward: the window only has to be on screen to
    /// run the launch, so it comes back behind whatever the user is doing when it was closed, and is
    /// left in the Dock when it was minimized. What happens once the session is ready is the Session
    /// Ready preference's decision, exactly as it is for a launch from the catalog.
    ///
    /// On screen, not merely existing: closing the window hides the scene's window, its surface
    /// detaches with it, and a launch handed to a window that is not showing is parked with nothing to
    /// act on it — which is what happened here before `needsPresentation` asked the right question.
    private func launch(_ game: OPNMenuBarRecentGame) {
        if OPNMainWindow.needsPresentation {
            // A window is about to be on screen again, so it comes with its Dock icon even though the
            // launch itself leaves it behind whatever the user is doing.
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
    /// Dock is brought back with its place kept; a closed one is rebuilt by the scene above it.
    private func openMainWindow() {
        // The window comes back with its Dock icon: menu-bar-only mode is a trade made while closed.
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
