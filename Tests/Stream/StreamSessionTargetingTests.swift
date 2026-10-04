//  Two accounts can stream at once, so a control has to reach the session it names. "The one started
//  most recently" is only right for the app-wide surfaces - the quit prompt and the shortcuts.
//  Serialized over the shared lifecycle.

import Foundation
import Testing
@testable import OpenNOW

@MainActor @Suite(.serialized, .streamLifecycleExclusive) struct StreamSessionTargetingTests {
    @Test func aCommandReachesOnlyTheSessionItNames() {
        let first = UUID()
        let second = UUID()
        var firstCommands: [StreamCommand] = []
        var secondCommands: [StreamCommand] = []
        StreamSessionLifecycle.activate(first, quitRequestHandler: { _ in true }, commandHandler: { firstCommands.append($0) })
        StreamSessionLifecycle.activate(second, quitRequestHandler: { _ in true }, commandHandler: { secondCommands.append($0) })
        defer {
            StreamSessionLifecycle.deactivate(first)
            StreamSessionLifecycle.deactivate(second)
        }

        #expect(StreamSessionLifecycle.sendCommand(.endSession, to: first))

        #expect(firstCommands == [.endSession])
        #expect(secondCommands.isEmpty)
        #expect(StreamSessionLifecycle.isActive(second))
    }

    @Test func aCommandForASessionThatIsNotLiveReachesNobody() {
        let live = UUID()
        let gone = UUID()
        var commands: [StreamCommand] = []
        StreamSessionLifecycle.activate(live, quitRequestHandler: { _ in true }, commandHandler: { commands.append($0) })
        StreamSessionLifecycle.activate(gone, quitRequestHandler: { _ in true }, commandHandler: { commands.append($0) })
        StreamSessionLifecycle.deactivate(gone)
        defer { StreamSessionLifecycle.deactivate(live) }

        #expect(!StreamSessionLifecycle.sendCommand(.pauseSession, to: gone))
        #expect(commands.isEmpty)
        #expect(!StreamSessionLifecycle.isActive(gone))
        #expect(StreamSessionLifecycle.isActive(live))
    }

    /// The quit prompt and the keyboard shortcuts are app-wide, so they keep reaching the session
    /// started most recently.
    @Test func anUntargetedCommandReachesTheSessionStartedMostRecently() {
        let first = UUID()
        let second = UUID()
        var firstCommands: [StreamCommand] = []
        var secondCommands: [StreamCommand] = []
        StreamSessionLifecycle.activate(first, quitRequestHandler: { _ in true }, commandHandler: { firstCommands.append($0) })
        StreamSessionLifecycle.activate(second, quitRequestHandler: { _ in true }, commandHandler: { secondCommands.append($0) })
        defer {
            StreamSessionLifecycle.deactivate(first)
            StreamSessionLifecycle.deactivate(second)
        }

        #expect(StreamSessionLifecycle.mostRecentlyActivatedID == second)
        #expect(StreamSessionLifecycle.sendCommand(.toggleMicrophone))

        #expect(secondCommands == [.toggleMicrophone])
        #expect(firstCommands.isEmpty)
    }
}
