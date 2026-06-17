import Foundation

public typealias WebRTCMediaStreamQuitDecisionHandler = @MainActor @Sendable (_ shouldTerminateApplication: Bool) -> Void
public typealias WebRTCMediaStreamQuitRequestHandler = @MainActor @Sendable (_ completion: @escaping WebRTCMediaStreamQuitDecisionHandler) -> Bool

@MainActor
public enum WebRTCMediaStreamLifecycle {
    private static var activeStreamIDs: [UUID] = []
    private static var quitRequestHandlers: [UUID: WebRTCMediaStreamQuitRequestHandler] = [:]

    public static var hasActiveStream: Bool {
        !activeStreamIDs.isEmpty
    }

    public static func activate(_ id: UUID, quitRequestHandler: @escaping WebRTCMediaStreamQuitRequestHandler) {
        activeStreamIDs.removeAll { $0 == id }
        activeStreamIDs.append(id)
        quitRequestHandlers[id] = quitRequestHandler
    }

    public static func deactivate(_ id: UUID) {
        activeStreamIDs.removeAll { $0 == id }
        quitRequestHandlers.removeValue(forKey: id)
    }

    public static func requestApplicationQuitDecision(completion: @escaping WebRTCMediaStreamQuitDecisionHandler) -> Bool {
        guard let id = activeStreamIDs.last, let handler = quitRequestHandlers[id] else { return false }
        return handler(completion)
    }
}
