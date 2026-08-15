enum NativeNVSTMouseInput: Equatable, Sendable {
    case event(UserInputEvent)
    case absoluteMove(NativeNVSTAbsoluteMouseEvent)
}

final class NativeNVSTMouseInputDispatcher: Sendable {
    private let continuation: AsyncStream<NativeNVSTMouseInput>.Continuation
    private let drainTask: Task<Void, Never>

    init(send: @escaping @Sendable (NativeNVSTMouseInput) async -> Void) {
        let channel = AsyncStream<NativeNVSTMouseInput>.makeStream(bufferingPolicy: .unbounded)
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
