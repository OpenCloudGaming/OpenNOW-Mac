final class NativeNVSTMouseInputDispatcher: Sendable {
    private let continuation: AsyncStream<UserInputEvent>.Continuation
    private let drainTask: Task<Void, Never>

    init(send: @escaping @Sendable (UserInputEvent) async -> Void) {
        let channel = AsyncStream<UserInputEvent>.makeStream(bufferingPolicy: .unbounded)
        continuation = channel.continuation
        drainTask = Task {
            for await event in channel.stream {
                guard !Task.isCancelled else { return }
                await send(event)
            }
        }
    }

    func enqueue(_ event: UserInputEvent) {
        continuation.yield(event)
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
