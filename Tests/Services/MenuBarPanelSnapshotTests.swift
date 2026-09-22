import AppKit
import Observation
import SwiftUI
import Testing
@testable import OpenNOW

/// The status item's popover, rendered so a person can look at it.
///
/// Two kinds of capture, both opt-in through `OPN_SNAPSHOT_DIR` — the same directory the HUD panel
/// snapshots write into. Nothing is written on a normal run, and the assertions here are what gate
/// the suite.
///
/// - **Offscreen snapshots** of the panel's layout: `ImageRenderer` needs no screen and no capture
///   permission, which is what makes them safe to run anywhere.
/// - **Composited captures** of the chrome: Liquid Glass is drawn by the window server, so
///   `glassEffect` renders as nothing into an `ImageRenderer`, and a screen grab comes back black
///   while the display is asleep or the session is locked. Those put the panel in a real window over
///   a high-contrast backdrop and capture what the window server composed — which is why they skip
///   unless a capture directory was asked for.
///
/// One platform limit for reading a capture: `ImageRenderer` does not rasterize `ScrollView` content,
/// so a capped list's rows are verified by the composited captures, not by an offscreen image.
@MainActor @Suite(.serialized, .streamLifecycleExclusive) struct MenuBarPanelSnapshotTests {
    /// Opt-in capture directory. Read once, here, so every capture in this file agrees.
    nonisolated private static var captureDirectory: String? {
        ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"]
    }

    nonisolated private static var captureEnabled: Bool {
        captureDirectory != nil
    }

    private static let games = [
        OPNMenuBarGame(title: "Cyberpunk 2077", appId: "app-1", lastPlayedAt: Date().addingTimeInterval(-2 * 3600)),
        OPNMenuBarGame(title: "Manor Lords", appId: "app-2", lastPlayedAt: Date().addingTimeInterval(-26 * 3600)),
        OPNMenuBarGame(title: "Elden Ring: Shadow of the Erdtree", appId: "app-3", lastPlayedAt: Date().addingTimeInterval(-3 * 86_400)),
    ]

    /// Seven, so the Favorites tab renders past the five-row cap and exercises the scrolling path.
    private static let favorites = (1...7).map { OPNMenuBarGame(title: "Favorite \($0)", appId: "fav-\($0)") }

    /// Seven collections and a member list past the cap, so both Collections surfaces render their
    /// scrolling paths.
    private static let collections = (1...7).map { index in
        OPNMenuBarCollection(
            id: "collection-\(index)",
            name: "Collection \(index)",
            icon: .symbol("sparkles"),
            gameCount: index,
            games: (1...index).map { OPNMenuBarGame(title: "Collection \(index) Game \($0)", appId: "collection-\(index)-game-\($0)") }
        )
    }

    /// One collection with more members than the list shows at once.
    private static let spaceGames = OPNMenuBarCollection(
        id: "collection-space",
        name: "Space Games",
        icon: .symbol("sparkles"),
        gameCount: 7,
        games: (1...7).map { OPNMenuBarGame(title: "Space Game \($0)", appId: "space-\($0)") }
    )

    // MARK: - Layout

    @Test func thePanelRendersInEveryPhase() async throws {
        let states: [(String, OPNMenuBarSessionPhase, String)] = [
            ("idle", .idle, ""),
            ("streaming", .streaming, "Cyberpunk 2077"),
            ("queued", .queued(position: 4), "Cyberpunk 2077"),
            ("starting", .starting, "Cyberpunk 2077"),
            ("connecting", .connecting, "Manor Lords"),
        ]
        for (name, phase, title) in states {
            try await withPanel(phase: phase, title: title) { panel in
                try render(panel, named: "menu-bar-panel-\(name).png", minimumHeight: 160)
            }
        }
    }

    @Test func thePanelRendersWithoutRecentGames() async throws {
        try await withPanel(phase: .idle, title: "", recentGames: []) { panel in
            try render(panel, named: "menu-bar-panel-empty.png", minimumHeight: 120)
        }
    }

    /// The Favorites tab with a list short of the cap: the panel takes its natural height and no
    /// scroll view is introduced.
    @Test func theFavoritesTabRendersAShortList() async throws {
        try await withPanel(phase: .idle, title: "", favorites: Array(Self.favorites.prefix(3)), initialTab: .favorites) { panel in
            try render(panel, named: "menu-bar-panel-favorites.png", minimumHeight: 160)
        }
    }

    /// Seven favorites on the tab: the list holds the five-row cap and scrolls, rather than growing
    /// the popover with every entry.
    @Test func theFavoritesTabHoldsTheCapPastFiveRows() async throws {
        try await withPanel(phase: .idle, title: "", favorites: Self.favorites, initialTab: .favorites) { panel in
            try render(panel, named: "menu-bar-panel-favorites-scrolling.png", minimumHeight: 200)
        }
    }

    /// Three collections on the tab, short of the cap: the panel takes its natural height, the rows
    /// render offscreen, and no scroll view is introduced.
    @Test func theCollectionsTabRendersAShortList() async throws {
        try await withPanel(phase: .idle, title: "", collections: Array(Self.collections.prefix(3)), initialTab: .collections) { panel in
            try render(panel, named: "menu-bar-panel-collections.png", minimumHeight: 160)
        }
    }

    /// Seven collections on the tab: the list holds the five-row cap rather than growing the popover
    /// with every entry. The cap is checked by the height here and by the composited capture below.
    @Test func theCollectionsTabHoldsTheCapPastFiveRows() async throws {
        try await withPanel(phase: .idle, title: "", collections: Self.collections, initialTab: .collections) { panel in
            try render(panel, named: "menu-bar-panel-collections-scrolling.png", minimumHeight: 200)
        }
    }

    /// One collection's members, opened from the list and short of the cap, so every row renders.
    @Test func aCollectionDetailRendersAShortListOfGames() async throws {
        let collection = OPNMenuBarCollection(
            id: "collection-short",
            name: "Space Games",
            icon: .symbol("sparkles"),
            gameCount: 3,
            games: (1...3).map { OPNMenuBarGame(title: "Space Game \($0)", appId: "space-\($0)") }
        )
        try await renderCollectionCard(collection, named: "menu-bar-panel-collection-detail.png", minimumHeight: 200)
    }

    /// A collection whose members the catalog has not resolved: the detail says so rather than
    /// showing an empty list, and still reports the collection's real size.
    @Test func aCollectionDetailExplainsUnresolvedGames() async throws {
        let collection = OPNMenuBarCollection(id: "collection-pending", name: "Waiting Room", icon: nil, gameCount: 3, games: [])
        try await renderCollectionCard(collection, named: "menu-bar-panel-collection-pending.png", minimumHeight: 100)
    }

    /// The account card is fixed across tabs: it shows on Favorites too, above the list, rather than
    /// appearing only on the session surface.
    @Test func theAccountCardIsFixedOnTheFavoritesTab() async throws {
        let model = OPNMenuBarSessionModel()
        let source = PanelStubSource()
        source.snapshot = OPNMenuBarSessionSnapshot(
            phase: .idle,
            title: "",
            favorites: Array(Self.favorites.prefix(3)),
            accounts: [OPNMenuBarAccount(email: "anderson@example.com", displayName: "Anderson", membershipTier: "Ultimate", isSignedOut: false, isActive: true)]
        )
        model.attach(source: source)
        defer { model.detachSource(source) }
        try? await Task.sleep(for: .milliseconds(60))

        try render(OPNMenuBarPanel(session: model, initialTab: .favorites), named: "menu-bar-panel-favorites-accounts.png", minimumHeight: 240)
    }

    /// The account card is the first thing in the popover, so it is rendered over seeded accounts —
    /// more than one, which is the case that grows the header into a disclosure.
    @Test func thePanelRendersWithAccounts() throws {
        let model = OPNMenuBarSessionModel()
        model.primeAccounts([
            OPNMenuBarAccount(email: "anderson@example.com", displayName: "Anderson", membershipTier: "Ultimate", isSignedOut: false, isActive: true),
            OPNMenuBarAccount(email: "player2@example.com", displayName: "Player Two", membershipTier: "Free", isSignedOut: true, isActive: false),
        ])
        try render(OPNMenuBarPanel(session: model), named: "menu-bar-panel-accounts.png", minimumHeight: 140)
    }

    /// The account dropdown open. The popover only shows it after a click, so it is rendered on its
    /// own with the section started expanded.
    @Test func theAccountDropdownRendersExpanded() throws {
        let model = OPNMenuBarSessionModel()
        model.primeAccounts([
            OPNMenuBarAccount(email: "anderson@example.com", displayName: "Anderson", membershipTier: "Ultimate", isSignedOut: false, isActive: true),
            OPNMenuBarAccount(email: "player2@example.com", displayName: "Player Two", membershipTier: "Free", isSignedOut: false, isActive: false),
            OPNMenuBarAccount(email: "player3@example.com", displayName: "Player Three", membershipTier: "Free", isSignedOut: true, isActive: false),
        ])
        let content = OPNMenuBarAccountSection(session: model, startsExpanded: true, onPresentMainWindow: {})
            .padding(10)
            .frame(width: OPNMenuBarPanel.width)
            .opnMenuBarPanelBackground()
            .background(Color.black)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "the expanded account dropdown did not render")
        #expect(image.size.width >= OPNMenuBarPanel.width, "the dropdown collapsed horizontally")
        #expect(image.size.height > 180, "the dropdown collapsed vertically")

        guard let directory = Self.captureDirectory,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("menu-bar-account-dropdown.png"))
    }

    /// `streaming` is not something a source can claim — the surface takes it from the stream
    /// lifecycle — so a streaming panel is rendered over a real activated session, ended again
    /// before the next state so nothing leaks between renders.
    private func withPanel(
        phase: OPNMenuBarSessionPhase,
        title: String,
        recentGames: [OPNMenuBarGame] = MenuBarPanelSnapshotTests.games,
        favorites: [OPNMenuBarGame] = [],
        collections: [OPNMenuBarCollection] = [],
        initialTab: OPNMenuBarTab = .session,
        _ body: (OPNMenuBarPanel) throws -> Void
    ) async rethrows {
        let model = OPNMenuBarSessionModel()
        let source = PanelStubSource()
        source.snapshot = OPNMenuBarSessionSnapshot(phase: phase, title: title, recentGames: recentGames, favorites: favorites, collections: collections)
        model.attach(source: source)
        defer { model.detachSource(source) }

        let streamID = phase == .streaming ? UUID() : nil
        if let streamID {
            StreamSessionLifecycle.activate(streamID, quitRequestHandler: { _ in true })
        }
        defer {
            if let streamID { StreamSessionLifecycle.deactivate(streamID) }
        }

        // The surface follows its source by change, so the first applied snapshot needs the main
        // queue to turn before the render reads it.
        try? await Task.sleep(for: .milliseconds(60))
        try body(OPNMenuBarPanel(session: model, initialTab: initialTab))
    }

    private func render(_ panel: OPNMenuBarPanel, named name: String, minimumHeight: CGFloat) throws {
        try renderContent(panel.background(Color.black), named: name, minimumHeight: minimumHeight)
    }

    /// A collection's detail card rendered on its own, over a model whose snapshot carries the
    /// collection; the selection is constant because a snapshot render never navigates.
    private func renderCollectionCard(_ collection: OPNMenuBarCollection, named name: String, minimumHeight: CGFloat) async throws {
        let model = OPNMenuBarSessionModel()
        let source = PanelStubSource()
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "", collections: [collection])
        model.attach(source: source)
        defer { model.detachSource(source) }
        try? await Task.sleep(for: .milliseconds(60))

        let card = OPNMenuBarCollectionsCard(session: model, selectedCollectionId: .constant(collection.id), onLaunchGame: { _ in })
            .padding(10)
            .frame(width: OPNMenuBarPanel.width)
            .opnMenuBarPanelBackground()
            .background(Color.black)
        try renderContent(card, named: name, minimumHeight: minimumHeight)
    }

    private func renderContent(_ content: some View, named name: String, minimumHeight: CGFloat) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "\(name) did not render")
        #expect(image.size.width >= OPNMenuBarPanel.width, "\(name) collapsed horizontally")
        #expect(image.size.height > minimumHeight, "\(name) collapsed vertically")
        // Written where a person can look at it; the assertions above are what gate the test.
        guard let directory = Self.captureDirectory,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    // MARK: - Chrome, as the window server composes it

    /// The panel over a high-contrast backdrop in a real window: Liquid Glass is only legible as
    /// glass when there is something behind it to blur and pick colour from. The companion capture
    /// below renders the same backdrop with no panel over it as the control.
    @Test(.enabled(if: captureEnabled)) func theGlassChromeRendersInAWindow() async throws {
        let model = OPNMenuBarSessionModel()
        let source = PanelStubSource()
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "", recentGames: Self.games)
        model.attach(source: source)
        defer { model.detachSource(source) }
        try await Task.sleep(for: .milliseconds(80))

        try await captureInWindow(OPNMenuBarPanel(session: model), named: "menu-bar-glass-over-backdrop.png", height: 330)
    }

    /// The Collections tab with the scrolling paths on screen: seven members in the open collection.
    /// This is the capture that verifies what an offscreen render cannot.
    @Test(.enabled(if: captureEnabled)) func theCollectionsChromeRendersInAWindow() async throws {
        let model = OPNMenuBarSessionModel()
        let source = PanelStubSource()
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "", collections: [Self.spaceGames])
        model.attach(source: source)
        defer { model.detachSource(source) }
        try await Task.sleep(for: .milliseconds(80))

        let card = OPNMenuBarCollectionsCard(session: model, selectedCollectionId: .constant(Self.spaceGames.id), onLaunchGame: { _ in })
            .padding(10)
            .frame(width: OPNMenuBarPanel.width)
        try await captureInWindow(card, named: "menu-bar-collections-over-backdrop.png", height: 420)
    }

    /// The control for the capture above: the same backdrop with no panel over it, so the blur the
    /// glass introduces can be seen rather than taken on trust.
    @Test(.enabled(if: captureEnabled)) func theBackdropRendersWithoutThePanel() async throws {
        let directory = try #require(Self.captureDirectory, "set OPN_SNAPSHOT_DIR to capture")

        let hosting = NSHostingView(rootView: GlassEvidenceBackdrop())
        hosting.frame = NSRect(x: 0, y: 0, width: OPNMenuBarPanel.width, height: 330)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: 200, y: 260))
        window.orderFrontRegardless()

        try await Task.sleep(for: .milliseconds(700))
        let image = captureWindow(CGWindowID(window.windowNumber))
        window.orderOut(nil)

        try write(try #require(image, "no image for the backdrop window"), named: "menu-bar-glass-backdrop.png", into: directory)
    }

    /// The popover where it actually lives: find the running app's status item, click it, and grab
    /// the region it opens into. Needs the app running with windowless mode on and an unlocked
    /// session, so it reports and returns rather than failing when that is not the case.
    @Test(.enabled(if: captureEnabled)) func theRealPopoverIsCaptured() async throws {
        let directory = try #require(Self.captureDirectory, "set OPN_SNAPSHOT_DIR to capture")

        guard let statusItem = onScreenWindows(ownedBy: "OpenNOW Dev").first(where: { $0.bounds.height < 40 }) else {
            print("no OpenNOW status item on screen — launch the app with windowless mode on and unlock the session")
            return
        }
        let clickPoint = CGPoint(x: statusItem.bounds.midX, y: statusItem.bounds.midY)
        click(clickPoint)
        try await Task.sleep(for: .milliseconds(1000))

        // The menu bar plus the panel below it, with the desktop it is glass over.
        let region = CGRect(x: max(0, clickPoint.x - 280), y: 0, width: 560, height: 640)
        let image = try #require(captureRegion(region), "the screen capture returned nothing")
        try write(image, named: "menu-bar-glass-popover-live.png", into: directory)

        // Leave the machine as it was found.
        click(clickPoint)
    }

    private struct WindowInfo {
        let bounds: CGRect
    }

    /// Puts `content` in a real borderless window over the backdrop and captures what the window
    /// server composed, waiting once for the window and once for the first real draw.
    private func captureInWindow(_ content: some View, named name: String, height: CGFloat) async throws {
        let directory = try #require(Self.captureDirectory, "set OPN_SNAPSHOT_DIR to capture")

        let hosting = NSHostingView(
            rootView: ZStack(alignment: .top) {
                GlassEvidenceBackdrop()
                content
            }
        )
        hosting.frame = NSRect(x: 0, y: 0, width: OPNMenuBarPanel.width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: 200, y: 260))
        window.orderFrontRegardless()

        try await Task.sleep(for: .milliseconds(1200))
        _ = captureWindow(CGWindowID(window.windowNumber))
        try await Task.sleep(for: .milliseconds(400))
        let captured = captureWindow(CGWindowID(window.windowNumber))
        window.orderOut(nil)

        try write(
            try #require(captured, "the window server returned no image for our own window"),
            named: name,
            into: directory
        )
    }

    private func onScreenWindows(ownedBy owner: String) -> [WindowInfo] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard (entry[kCGWindowOwnerName as String] as? String) == owner,
                  let raw = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = raw["X"], let y = raw["Y"], let width = raw["Width"], let height = raw["Height"] else { return nil }
            return WindowInfo(bounds: CGRect(x: x, y: y, width: width, height: height))
        }
    }

    /// `CGWindowListCreateImage` left this SDK's headers but is still exported by CoreGraphics, and
    /// it is the one composited capture that does not go through ScreenCaptureKit's permission gate.
    private func capture(_ region: CGRect, option: CGWindowListOption, window: CGWindowID) -> CGImage? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        typealias CaptureFunction = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
        let function = unsafeBitCast(symbol, to: CaptureFunction.self)
        let options = CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue
        return function(region, option.rawValue, window, options)?.takeRetainedValue()
    }

    private func captureWindow(_ window: CGWindowID) -> CGImage? {
        capture(.null, option: .optionIncludingWindow, window: window)
    }

    private func captureRegion(_ region: CGRect) -> CGImage? {
        capture(region, option: .optionOnScreenOnly, window: kCGNullWindowID)
    }

    private func click(_ point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(60_000)
        }
    }

    private func write(_ image: CGImage, named name: String, into directory: String) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let png = try #require(bitmap.representation(using: .png, properties: [:]), "could not encode \(name)")
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}

/// Fine stripes and heavy type, so a blur is unmistakable: sharp where it is not behind glass,
/// smeared where it is.
private struct GlassEvidenceBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.purple, .orange, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 6) {
                ForEach(0..<40, id: \.self) { index in
                    Rectangle()
                        .fill(.white.opacity(index.isMultiple(of: 2) ? 0.85 : 0.15))
                        .frame(height: 6)
                }
            }
            Text("BEHIND THE GLASS")
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(.black)
                .rotationEffect(.degrees(-12))
        }
    }
}

/// A stand-in launch flow: the panel follows whatever it publishes.
@MainActor @Observable private final class PanelStubSource: OPNMenuBarSessionSource {
    var snapshot = OPNMenuBarSessionSnapshot()
    var menuBarSnapshot: OPNMenuBarSessionSnapshot { snapshot }

    func launchGame(_ game: OPNMenuBarGame) {}
    func resumeSession() {}
    func refreshActiveSession() {}
    func showMainPage(_ page: OPNMainWindowPage) {}
    func switchAccount(_ account: OPNMenuBarAccount) {}
    func addAccount() {}
}
