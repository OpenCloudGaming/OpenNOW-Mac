enum NativeNVSTInput: Equatable, Sendable {
    case event(UserInputEvent)
    case absoluteMove(NativeNVSTAbsoluteMouseEvent)
}

final class NativeNVSTInputDispatcher: Sendable {
    private let continuation: AsyncStream<NativeNVSTInput>.Continuation
    private let drainTask: Task<Void, Never>

    init(send: @escaping @Sendable (NativeNVSTInput) async -> Void) {
        let channel = AsyncStream<NativeNVSTInput>.makeStream(bufferingPolicy: .unbounded)
        continuation = channel.continuation
        drainTask = Task {
            for await event in channel.stream {
                guard !Task.isCancelled else { return }
                await send(event)
            }
        }
    }

    func enqueue(_ event: UserInputEvent) {
        continuation.yield(.event(event))
    }

    func enqueueAbsoluteMove(_ event: NativeNVSTAbsoluteMouseEvent) {
        continuation.yield(.absoluteMove(event))
    }

    static func isNeutralizing(_ event: UserInputEvent) -> Bool {
        switch event {
        case .keyboard(let keyboard):
            return !keyboard.isPressed
        case .mouse(.button(_, _, let isPressed, _)):
            return !isPressed
        case .gamepad(let state):
            return state.buttons.isEmpty && state.leftTrigger == 0 && state.rightTrigger == 0 &&
                state.leftStickX == 0 && state.leftStickY == 0 && state.rightStickX == 0 && state.rightStickY == 0
        case .mouse, .text:
            return false
        }
    }

    func finish() async {
        continuation.finish()
        await drainTask.value
    }

    func cancel() {
        continuation.finish()
        drainTask.cancel()
    }

    deinit {
        continuation.finish()
        drainTask.cancel()
    }
}
