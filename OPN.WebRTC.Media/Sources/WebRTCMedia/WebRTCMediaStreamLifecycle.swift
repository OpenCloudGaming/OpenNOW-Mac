import Foundation

public typealias WebRTCMediaStreamQuitDecisionHandler = @MainActor @Sendable (_ shouldTerminateApplication: Bool) -> Void
public typealias WebRTCMediaStreamQuitRequestHandler = @MainActor @Sendable (_ completion: @escaping WebRTCMediaStreamQuitDecisionHandler) -> Bool
public typealias WebRTCMediaStreamCommandHandler = @MainActor @Sendable (_ command: WebRTCMediaStreamCommand) -> Void

@MainActor
public enum WebRTCMediaStreamLifecycle {
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
    }

    public static func deactivate(_ id: UUID) {
        activeStreamIDs.removeAll { $0 == id }
        quitRequestHandlers.removeValue(forKey: id)
        commandHandlers.removeValue(forKey: id)
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
