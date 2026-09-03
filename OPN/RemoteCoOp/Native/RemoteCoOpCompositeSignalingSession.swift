//  Presents several signaling transports - the embedded server for browser guests, the native
//  listener for OpenNOW guests - as the single session the coordinator and peer controller
//  expect.
//
//  Events merge: a join is a join whether it arrived over a WebSocket or a TCP socket. Commands
//  fan out to every transport: each transport routes or ignores by participant ID, which is what
//  each already does with commands meant for its own guests.
//

import Foundation

public final class OPNRemoteCoOpCompositeSignalingSession: OPNRemoteCoOpSignalingSession, @unchecked Sendable {
    private let sessions: [any OPNRemoteCoOpSignalingSession]

    public init(sessions: [any OPNRemoteCoOpSignalingSession]) {
        self.sessions = sessions
    }

    public func events() -> AsyncStream<OPNRemoteCoOpSignalingEvent> {
        let sessions = self.sessions
        return AsyncStream(bufferingPolicy: .bufferingNewest(240)) { continuation in
            let forwarding = Task {
                // Finished once every transport has finished, not merely dropped: each child adapter
                // finishes its own stream on `close()` for exactly this reason, and a merged stream
                // that only ended by consumer cancellation silently reversed that for everything
                // above it.
                await withTaskGroup(of: Void.self) { group in
                    for session in sessions {
                        group.addTask {
                            for await event in session.events() {
                                continuation.yield(event)
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                forwarding.cancel()
            }
        }
    }

    public func send(_ command: OPNRemoteCoOpSignalingCommand) async {
        for session in sessions { await session.send(command) }
    }

    public func close() async {
        for session in sessions { await session.close() }
    }
}
