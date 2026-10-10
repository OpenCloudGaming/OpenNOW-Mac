import AppKit
import SwiftUI
import Testing

/// The two SwiftUI behaviours the home rail's materialization window is built on. Both are load
/// bearing and neither is obvious from the call site, so they are pinned here against a real hosted
/// window rather than assumed:
///
/// - `onScrollVisibilityChange` reports the rails above the fold visible on the first frame and the
///   rails below it not visible, which is what lets an off-screen rail skip warming artwork.
/// - `onScrollGeometryChange` with a `Bool` reports the trailing edge once the rail has been
///   scrolled to it, and not before, which is what lets the window grow without growing on the
///   first frame - a window that grew on layout would materialize the whole rail and defeat the cap.
///
/// The fixture is the page's own shape: an eager `VStack` in a vertical `ScrollView`, with each rail
/// a `VStack` holding a horizontal `ScrollView`. Hosted windows are unstable under
/// `swiftpm-testing-helper` on CI runners, so this is a local gate like the hover tests.
@Suite(.serialized, .disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason))) @MainActor
struct CatalogRailWindowTriggerTests {
    @Test func theRailsBelowTheFoldAreNotReportedVisibleOnTheFirstFrame() async {
        let fixture = RailWindowFixture()
        defer { fixture.close() }
        await fixture.settle()

        #expect(fixture.visibility(for: .first) == [true])
        #expect(fixture.visibility(for: .belowFold) == [false])

        fixture.scrollPageToEnd()
        await fixture.settle()

        #expect(fixture.visibility(for: .belowFold) == [false, true])
    }

    @Test func theTrailingEdgeIsReportedOnlyOnceTheRailIsScrolledToIt() async {
        let fixture = RailWindowFixture()
        defer { fixture.close() }
        await fixture.settle()

        // The first frame is a rail at its leading edge, so the trigger stays closed: a window that
        // grew here would materialize the whole rail before the reader ever scrolled.
        #expect(fixture.trailingEdgeReports(for: .first) == [false])

        fixture.scrollRailToEnd(.first)
        await fixture.settle()

        #expect(fixture.trailingEdgeReports(for: .first) == [false, true])
        // The rail below the fold was never scrolled, so it never crossed the trigger.
        #expect(fixture.trailingEdgeReports(for: .belowFold) == [false])
    }
}

private enum RailFixtureRail {
    case first
    case belowFold
}

private struct RailWindowFixtureContent: View {
    let state: RailWindowFixtureState

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                rail(.first)
                Color.clear.frame(height: 2000)
                rail(.belowFold)
            }
        }
    }

    private func rail(_ rail: RailFixtureRail) -> some View {
        VStack(spacing: 0) {
            Color.gray.frame(height: 40)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { index in
                        Color.blue.frame(width: 200, height: 100).id(index)
                    }
                }
            }
            .frame(height: 100)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.width - geometry.contentOffset.x - geometry.containerSize.width <= RailWindowFixtureState.triggerDistance
            } action: { _, isNearTrailingEdge in
                state.trailingEdgeReports[rail, default: []].append(isNearTrailingEdge)
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { isVisible in
            state.visibilityReports[rail, default: []].append(isVisible)
        }
    }
}

@MainActor
private final class RailWindowFixtureState {
    /// Half a screen of a 400pt viewport showing 200pt slots.
    static let triggerDistance: CGFloat = 300
    var visibilityReports: [RailFixtureRail: [Bool]] = [:]
    var trailingEdgeReports: [RailFixtureRail: [Bool]] = [:]
}

@MainActor
private final class RailWindowFixture {
    private let state = RailWindowFixtureState()
    private let window: NSWindow
    private let hosting: NSHostingView<RailWindowFixtureContent>

    init() {
        hosting = NSHostingView(rootView: RailWindowFixtureContent(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
    }

    func visibility(for rail: RailFixtureRail) -> [Bool] {
        state.visibilityReports[rail] ?? []
    }

    func trailingEdgeReports(for rail: RailFixtureRail) -> [Bool] {
        state.trailingEdgeReports[rail] ?? []
    }

    func scrollPageToEnd() {
        guard let page = scrollViews().first(where: { ($0.documentView?.frame.height ?? 0) > $0.frame.height + 1 }),
              let document = page.documentView else { return }
        scroll(page, to: NSPoint(x: 0, y: document.frame.height - page.frame.height))
    }

    func scrollRailToEnd(_ rail: RailFixtureRail) {
        let horizontals = scrollViews().filter { ($0.documentView?.frame.width ?? 0) > $0.frame.width + 1 }
        let index = rail == .first ? 0 : 1
        guard horizontals.indices.contains(index), let document = horizontals[index].documentView else { return }
        scroll(horizontals[index], to: NSPoint(x: document.frame.width - horizontals[index].frame.width, y: 0))
    }

    func settle() async {
        for _ in 0..<20 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func close() {
        window.close()
    }

    private func scroll(_ scrollView: NSScrollView, to origin: NSPoint) {
        let clipView = scrollView.contentView
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func scrollViews() -> [NSScrollView] {
        var found: [NSScrollView] = []
        Self.collectScrollViews(in: hosting, into: &found)
        return found
    }

    private static func collectScrollViews(in view: NSView, into found: inout [NSScrollView]) {
        if let scrollView = view as? NSScrollView { found.append(scrollView) }
        for subview in view.subviews { collectScrollViews(in: subview, into: &found) }
    }
}
