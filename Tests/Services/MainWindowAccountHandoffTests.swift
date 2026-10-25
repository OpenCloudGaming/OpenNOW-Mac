import AppKit
import Testing
@testable import OpenNOW

@MainActor
@Suite(.serialized) struct MainWindowAccountHandoffTests {
    @Test func signInRisesAboveEveryObstructionUntilTheHandoffEnds() {
        let main = makeWindow()
        let detached = makeWindow()
        let covering = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 20)
        detached.level = NSWindow.Level(rawValue: covering.rawValue + 4)
        let handoff = OPNMainWindowAccountHandoff(mainWindow: { main }, coveringLevels: { [covering] })
        defer {
            handoff.end()
            main.close()
            detached.close()
        }

        handoff.begin(from: detached)

        #expect(main.level.rawValue > covering.rawValue)
        #expect(main.level.rawValue > detached.level.rawValue)
        #expect(main.isVisible)
        handoff.end()
        #expect(main.level == .normal)
        #expect(detached.level.rawValue == covering.rawValue + 4)
    }

    @Test func anAbsentMainSceneReceivesThePendingElevationWhenItAttaches() {
        let main = makeWindow()
        let covering = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 8)
        let handoff = OPNMainWindowAccountHandoff(mainWindow: { nil }, coveringLevels: { [covering] })
        defer {
            handoff.end()
            main.close()
        }

        handoff.begin(from: nil)
        #expect(main.level == .normal)
        handoff.attach(main)

        #expect(main.level.rawValue == covering.rawValue + 1)
        handoff.end()
        #expect(main.level == .normal)
    }

    @Test func coveringLevelChangesAreObservedOnlyForTheLifetimeOfTheHandoff() {
        let main = makeWindow()
        var covering = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        let handoff = OPNMainWindowAccountHandoff(mainWindow: { main }, coveringLevels: { [covering] })
        defer {
            handoff.end()
            main.close()
        }
        handoff.begin(from: nil)
        covering = NSWindow.Level(rawValue: covering.rawValue + 10)
        NotificationCenter.default.post(name: OPNStreamBorderless.coveringStateDidChange, object: nil)
        #expect(main.level.rawValue == covering.rawValue + 1)

        handoff.end()
        NotificationCenter.default.post(name: OPNStreamBorderless.coveringStateDidChange, object: nil)

        #expect(main.level == .normal)
    }

    @Test func ordinaryPresentationPreservesTheOriginalLevelAcrossRepeatedRequests() {
        let main = makeWindow()
        main.level = .floating
        let handoff = OPNMainWindowAccountHandoff(mainWindow: { main }, coveringLevels: { [] })
        defer {
            handoff.end()
            main.close()
        }

        handoff.begin(from: nil)
        handoff.begin(from: nil)
        #expect(main.level == .floating)
        handoff.end()

        #expect(main.level == .floating)
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
