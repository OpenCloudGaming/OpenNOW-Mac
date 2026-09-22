import Foundation
import Testing
@testable import OpenNOW

/// The settings surface's route to a stream it does not own: it either reaches the live session's
/// own input path or says `false` — never swallows the event. Serialized over the shared lifecycle.
@MainActor @Suite(.serialized, .streamLifecycleExclusive) struct StreamSyntheticInputTests {
    @Test func withNoLiveSessionThereIsNothingToInjectInto() {
        #expect(!StreamSessionLifecycle.hasActiveStream)
        #expect(!StreamSessionLifecycle.sendSyntheticInput(.relativeMouseMove(deltaX: 10, deltaY: 0)))
    }

    @Test func aLiveSessionReceivesTheSyntheticEvent() {
        let id = UUID()
        var delivered: [UserInputEvent] = []
        StreamSessionLifecycle.activate(
            id,
            quitRequestHandler: { _ in true },
            inputInjector: { event in
                delivered.append(event)
                return true
            }
        )
        defer { StreamSessionLifecycle.deactivate(id) }

        let accepted = StreamSessionLifecycle.sendSyntheticInput(.relativeMouseMove(deltaX: 200, deltaY: 0))
        #expect(accepted)
        #expect(delivered.count == 1)
        guard case .mouse(.moved(_, 200, 0, _)) = delivered.first else {
            Issue.record("expected the injected move to arrive unchanged")
            return
        }
    }

    @Test func aSessionThatRefusesTheEventSaysSo() {
        // A surface that is tearing down refuses rather than swallowing. The caller has to be able to
        // tell "the turn ran" from "the stream was not ready", or the wizard reports a completed
        // calibration that never reached the game.
        let id = UUID()
        StreamSessionLifecycle.activate(id, quitRequestHandler: { _ in true }, inputInjector: { _ in false })
        defer { StreamSessionLifecycle.deactivate(id) }

        #expect(!StreamSessionLifecycle.sendSyntheticInput(.relativeMouseMove(deltaX: 1, deltaY: 0)))
    }

    @Test func aSessionWithoutAnInjectorRefusesInsteadOfCrashing() {
        let id = UUID()
        StreamSessionLifecycle.activate(id, quitRequestHandler: { _ in true })
        defer { StreamSessionLifecycle.deactivate(id) }

        #expect(!StreamSessionLifecycle.sendSyntheticInput(.relativeMouseMove(deltaX: 1, deltaY: 0)))
    }

    @Test func deactivatingASessionDropsItsInjector() {
        let id = UUID()
        StreamSessionLifecycle.activate(id, quitRequestHandler: { _ in true }, inputInjector: { _ in true })
        StreamSessionLifecycle.deactivate(id)

        #expect(!StreamSessionLifecycle.sendSyntheticInput(.relativeMouseMove(deltaX: 1, deltaY: 0)))
    }

    @Test func theMostRecentSessionIsTheOneInjectedInto() {
        // Same rule `sendCommand` follows: injection follows the session the app is showing.
        let first = UUID()
        let second = UUID()
        var target = "none"
        StreamSessionLifecycle.activate(first, quitRequestHandler: { _ in true }, inputInjector: { _ in
            target = "first"
            return true
        })
        StreamSessionLifecycle.activate(second, quitRequestHandler: { _ in true }, inputInjector: { _ in
            target = "second"
            return true
        })
        defer {
            StreamSessionLifecycle.deactivate(first)
            StreamSessionLifecycle.deactivate(second)
        }

        #expect(StreamSessionLifecycle.sendSyntheticInput(.relativeMouseMove(deltaX: 1, deltaY: 0)))
        #expect(target == "second")
    }
}
