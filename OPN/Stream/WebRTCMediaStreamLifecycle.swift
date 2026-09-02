import Foundation

public typealias WebRTCMediaStreamQuitDecisionHandler = @MainActor @Sendable (_ shouldTerminateApplication: Bool) -> Void
public typealias WebRTCMediaStreamQuitRequestHandler = @MainActor @Sendable (_ completion: @escaping WebRTCMediaStreamQuitDecisionHandler) -> Bool
public typealias WebRTCMediaStreamCommandHandler = @MainActor @Sendable (_ command: WebRTCMediaStreamCommand) -> Void

enum StreamAntiAFKInputPolicy {
    static let pollInterval = Duration.seconds(60)
    static let idleThresholdSeconds: TimeInterval = 210

    static func randomMouseDelta() -> (x: Int16, y: Int16) {
        var x = Int16(Int.random(in: -5...5))
        let y = Int16(Int.random(in: -5...5))
        if x == 0 && y == 0 { x = 1 }
        return (x, y)
    }

    static func mouseMove(deltaX: Int16, deltaY: Int16) -> UserInputEvent {
        .mouse(.moved(deviceID: "mouse", deltaX: deltaX, deltaY: deltaY, timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)))
    }
}

@MainActor
public enum WebRTCMediaStreamLifecycle {
    /// Posted whenever a stream starts or ends, so surfaces that must not interrupt gameplay — the
    /// update prompt — can wait for the stream to finish instead of polling `hasActiveStream`.
    public static let activeStreamDidChangeNotification = Notification.Name("OpenNOWActiveStreamDidChange")

    private static var activeStreamIDs: [UUID] = []
    private static var quitRequestHandlers: [UUID: WebRTCMediaStreamQuitRequestHandler] = [:]
    private static var commandHandlers: [UUID: WebRTCMediaStreamCommandHandler] = [:]

    public static var hasActiveStream: Bool {
        !activeStreamIDs.isEmpty
    }

    public static func activate(_ id: UUID, quitRequestHandler: @escaping WebRTCMediaStreamQuitRequestHandler, commandHandler: WebRTCMediaStreamCommandHandler? = nil) {
        activeStreamIDs.removeAll { $0 == id }
        activeStreamIDs.append(id)
        quitRequestHandlers[id] = quitRequestHandler
        commandHandlers[id] = commandHandler
        NotificationCenter.default.post(name: activeStreamDidChangeNotification, object: nil)
    }

    public static func deactivate(_ id: UUID) {
        activeStreamIDs.removeAll { $0 == id }
        quitRequestHandlers.removeValue(forKey: id)
        commandHandlers.removeValue(forKey: id)
        NotificationCenter.default.post(name: activeStreamDidChangeNotification, object: nil)
    }

    public static func requestApplicationQuitDecision(completion: @escaping WebRTCMediaStreamQuitDecisionHandler) -> Bool {
        guard let id = activeStreamIDs.last, let handler = quitRequestHandlers[id] else { return false }
        return handler(completion)
    }

    public static func sendCommand(_ command: WebRTCMediaStreamCommand) -> Bool {
        guard let id = activeStreamIDs.last, let handler = commandHandlers[id] else { return false }
        handler(command)
        return true
    }
}
