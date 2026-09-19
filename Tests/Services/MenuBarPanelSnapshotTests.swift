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
@MainActor @Suite(.serialized) struct MenuBarPanelSnapshotTests {
    /// Opt-in capture directory. Read once, here, so every capture in this file agrees.
    nonisolated private static var captureDirectory: String? {
        ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"]
    }

    nonisolated private static var captureEnabled: Bool {
        captureDirectory != nil
    }

    private static let games = [
        OPNMenuBarRecentGame(title: "Cyberpunk 2077", appId: "app-1"),
        OPNMenuBarRecentGame(title: "Manor Lords", appId: "app-2"),
        OPNMenuBarRecentGame(title: "Elden Ring: Shadow of the Erdtree", appId: "app-3"),
    ]

    // MARK: - Layout

    @Test func thePanelRendersInEveryPhase() async throws {
        let states: [(String, OPNMenuBarSessionPhase, String)] = [
            ("idle", .idle, ""),
            ("streaming", .streaming, "Cyberpunk 2077"),
            ("queued", .queued(position: 4), "Cyberpunk 2077"),
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

    /// `streaming` is not something a source can claim — the surface takes it from the stream
    /// lifecycle — so a streaming panel is rendered over a real activated session, ended again
    /// before the next state so nothing leaks between renders.
    private func withPanel(
        phase: OPNMenuBarSessionPhase,
        title: String,
        recentGames: [OPNMenuBarRecentGame] = MenuBarPanelSnapshotTests.games,
        _ body: (OPNMenuBarPanel) throws -> Void
    ) async rethrows {
        let model = OPNMenuBarSessionModel()
        let source = PanelStubSource()
        source.snapshot = OPNMenuBarSessionSnapshot(phase: phase, title: title, recentGames: recentGames)
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
        try body(OPNMenuBarPanel(session: model))
    }

    private func render(_ panel: OPNMenuBarPanel, named name: String, minimumHeight: CGFloat) throws {
        let renderer = ImageRenderer(content: panel.background(Color.black))
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
        let directory = try #require(Self.captureDirectory, "set OPN_SNAPSHOT_DIR to capture")

        let model = OPNMenuBarSessionModel()
        let source = PanelStubSource()
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "", recentGames: Self.games)
        model.attach(source: source)
        defer { model.detachSource(source) }
        try await Task.sleep(for: .milliseconds(80))

        let hosting = NSHostingView(
            rootView: ZStack(alignment: .top) {
                GlassEvidenceBackdrop()
                OPNMenuBarPanel(session: model)
            }
        )
        hosting.frame = NSRect(x: 0, y: 0, width: OPNMenuBarPanel.width, height: 330)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: 200, y: 260))
        window.orderFrontRegardless()

        // Two waits: one for the window server to put the window up, one for the first real draw —
        // a transparent borderless window can be captured before SwiftUI has drawn into it.
        try await Task.sleep(for: .milliseconds(1200))
        _ = captureWindow(CGWindowID(window.windowNumber))
        try await Task.sleep(for: .milliseconds(400))
        let captured = captureWindow(CGWindowID(window.windowNumber))
        window.orderOut(nil)

        try write(
            try #require(captured, "the window server returned no image for our own window"),
            named: "menu-bar-glass-over-backdrop.png",
            into: directory
        )
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

    func launchRecentGame(_ game: OPNMenuBarRecentGame) {}
    func resumeSession() {}
    func refreshActiveSession() {}
}
