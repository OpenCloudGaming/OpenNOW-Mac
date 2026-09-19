import AppKit
import SwiftUI

/// The status item's label: the game, what the session is doing, and a ticking elapsed clock.
struct OPNMenuBarStatusLabel: View {
    @ObservedObject var session: OPNMenuBarSessionModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
            Text(OPNMenuBarReadout.titleText(session.gameTitle))
            if let detail = session.statusDetailText() {
                Text(detail)
            }
            if let startedAt = session.streamStartedAt {
                // The system clock view ticks on its own; nothing here polls for it.
                Text(startedAt, style: .timer)
                    .monospacedDigit()
            }
        }
        .id(labelIdentity)
        .accessibilityLabel(session.accessibilityLabel())
    }

    /// Rebuilt when the surface changes what it is showing, so the status item cannot get stuck on
    /// a stale first render. Deliberately independent of the elapsed clock: recreating the label
    /// would restart the timer.
    private var labelIdentity: String {
        "\(session.phase)/\(session.gameTitle)"
    }

    private var symbolName: String {
        switch session.phase {
        case .idle: return "gamecontroller"
        case .queued, .connecting: return "hourglass"
        case .streaming: return "gamecontroller.fill"
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
                Image(systemName: sessionSymbolName)
                    .font(.opnUI(size: 15, weight: .bold))
                    .foregroundStyle(session.hasActiveStream ? OPNDesign.accent : OPNDesign.Text.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    // With no game to name, the status line is the card's headline rather than a
                    // subtitle under a redundant "OpenNOW".
                    if let title = OPNMenuBarReadout.panelTitleText(session.gameTitle) {
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
                if let startedAt = session.streamStartedAt {
                    Text(startedAt, style: .timer)
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
            controlTile("Microphone", systemImage: "mic.fill", isEnabled: session.hasActiveStream) {
                session.toggleMicrophone()
            }
            controlTile("Record", systemImage: "record.circle", isEnabled: session.hasActiveStream) {
                session.toggleRecording()
            }
            controlTile("End", systemImage: "stop.fill", tint: OPNDesign.Semantic.destructive, isEnabled: session.hasActiveStream) {
                session.endSession()
            }
        }
    }

    private var sessionSymbolName: String {
        switch session.phase {
        case .idle: return "gamecontroller"
        case .queued, .connecting: return "hourglass"
        case .streaming: return "gamecontroller.fill"
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

    /// A game started here does not bring the window forward: the window only has to exist to run
    /// the launch, so it is recreated behind whatever the user is doing when it was closed, and left
    /// in the Dock when it was minimized. What happens once the session is ready is the Session
    /// Ready preference's decision, exactly as it is for a launch from the catalog.
    private func launch(_ game: OPNMenuBarRecentGame) {
        if OPNMainWindow.existing() == nil { openWindow(id: "main") }
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
