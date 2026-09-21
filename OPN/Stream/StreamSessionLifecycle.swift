import Foundation

public typealias StreamSessionQuitDecisionHandler = @MainActor @Sendable (_ shouldTerminateApplication: Bool) -> Void
public typealias StreamSessionQuitRequestHandler = @MainActor @Sendable (_ completion: @escaping StreamSessionQuitDecisionHandler) -> Bool
public typealias StreamCommandHandler = @MainActor @Sendable (_ command: StreamCommand) -> Void
/// Hands one synthetic event to a live session through that session's own input path, returning
/// whether the session accepted it. A session that is tearing down, not yet ready, or already gone
/// answers `false` rather than dropping the event silently.
public typealias StreamInputInjector = @MainActor @Sendable (_ event: UserInputEvent) -> Bool

enum StreamAntiAFKInputPolicy {
    /// The poll phase is pinned to stream start, not to the last input, so the interval is the
    /// worst-case lateness of the first nudge: at 60 s a tick at 209 s of idle deferred the next
    /// check to 269 s. The tick itself is two date comparisons, so a short one costs nothing.
    static let pollInterval = Duration.seconds(15)
    /// UNVERIFIED against the seat: no capture or vendor note in this repo records the real idle
    /// timeout, so this is a margin chosen below the shortest reported one rather than a measured
    /// bound. Settle it by idling a session with anti-AFK off and recording the time to disconnect.
    static let idleThresholdSeconds: TimeInterval = 210

    static func randomMouseDelta() -> (x: Int16, y: Int16) {
        var x = Int16(Int.random(in: -5...5))
        let y = Int16(Int.random(in: -5...5))
        if x == 0 && y == 0 { x = 1 }
        return (x, y)
    }

    static func mouseMove(deltaX: Int16, deltaY: Int16) -> UserInputEvent {
        .relativeMouseMove(deltaX: deltaX, deltaY: deltaY)
    }
}

@MainActor
public enum StreamSessionLifecycle {
    /// Posted whenever a stream starts or ends, so surfaces that must not interrupt gameplay — the
    /// update prompt — can wait for the stream to finish instead of polling `hasActiveStream`.
    public static let activeStreamDidChangeNotification = Notification.Name("OPNActiveStreamDidChange")

    private static var activeStreamIDs: [UUID] = []
    private static var quitRequestHandlers: [UUID: StreamSessionQuitRequestHandler] = [:]
    private static var commandHandlers: [UUID: StreamCommandHandler] = [:]
    private static var inputInjectors: [UUID: StreamInputInjector] = [:]

    public static var hasActiveStream: Bool {
        !activeStreamIDs.isEmpty
    }

    public static func activate(_ id: UUID,
                                quitRequestHandler: @escaping StreamSessionQuitRequestHandler,
                                commandHandler: StreamCommandHandler? = nil,
                                inputInjector: StreamInputInjector? = nil) {
        activeStreamIDs.removeAll { $0 == id }
        activeStreamIDs.append(id)
        quitRequestHandlers[id] = quitRequestHandler
        commandHandlers[id] = commandHandler
        inputInjectors[id] = inputInjector
        NotificationCenter.default.post(name: activeStreamDidChangeNotification, object: nil)
    }

    public static func deactivate(_ id: UUID) {
        activeStreamIDs.removeAll { $0 == id }
        quitRequestHandlers.removeValue(forKey: id)
        commandHandlers.removeValue(forKey: id)
        inputInjectors.removeValue(forKey: id)
        NotificationCenter.default.post(name: activeStreamDidChangeNotification, object: nil)
    }

    public static func requestApplicationQuitDecision(completion: @escaping StreamSessionQuitDecisionHandler) -> Bool {
        guard let id = activeStreamIDs.last, let handler = quitRequestHandlers[id] else { return false }
        return handler(completion)
    }

    public static func sendCommand(_ command: StreamCommand) -> Bool {
        guard let id = activeStreamIDs.last, let handler = commandHandlers[id] else { return false }
        handler(command)
        return true
    }

    /// Injects one synthetic event into the live session — the route a settings surface uses to
    /// reach a stream it does not own.
    ///
    /// Deliberately not a second input path: the injector is a closure the live stream surface
    /// registers, and it sends through the same transport call the surface's own input already
    /// uses. Settings never learns which transport is live, so the two cannot disagree about how an
    /// event is encoded or paced. `false` means there was no live session to take it.
    public static func sendSyntheticInput(_ event: UserInputEvent) -> Bool {
        guard let id = activeStreamIDs.last, let injector = inputInjectors[id] else { return false }
        return injector(event)
    }
}
