import Foundation

enum NativeNVSTInput: Equatable, Sendable {
    case event(UserInputEvent)
    case absoluteMove(NativeNVSTAbsoluteMouseEvent)
}

final class NativeNVSTInputDispatcher: Sendable {
    static let defaultCapacity = 256

    private let buffer: NativeNVSTInputBuffer
    private let continuation: AsyncStream<Void>.Continuation
    private let drainTask: Task<Void, Never>

    init(capacity: Int = defaultCapacity, send: @escaping @Sendable (NativeNVSTInput) async -> Void) {
        let buffer = NativeNVSTInputBuffer(capacity: capacity)
        let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.buffer = buffer
        continuation = channel.continuation
        drainTask = Task {
            for await _ in channel.stream {
                while let input = buffer.removeFirst() {
                    guard !Task.isCancelled else { return }
                    await send(input)
                }
                if buffer.isFinished { return }
            }
        }
    }

    func enqueue(_ event: UserInputEvent) {
        enqueue(.event(event))
    }

    func enqueueAbsoluteMove(_ event: NativeNVSTAbsoluteMouseEvent) {
        enqueue(.absoluteMove(event))
    }

    var pendingInputCount: Int {
        buffer.count
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
        buffer.finish(discardingStaleInput: true)
        continuation.yield()
        continuation.finish()
        await drainTask.value
    }

    func cancel() {
        buffer.finish(discardingStaleInput: false)
        continuation.finish()
        drainTask.cancel()
    }

    deinit {
        buffer.finish(discardingStaleInput: false)
        continuation.finish()
        drainTask.cancel()
    }

    private func enqueue(_ input: NativeNVSTInput) {
        guard buffer.append(input) else { return }
        continuation.yield()
    }
}

private final class NativeNVSTInputBuffer: @unchecked Sendable {
    private let capacity: Int
    private let protectedCapacity: Int
    private let ordinaryCapacity: Int
    private let lock = NSLock()
    private var inputs: [NativeNVSTInput] = []
    private var finished = false

    init(capacity: Int) {
        let normalizedCapacity = max(1, capacity)
        self.capacity = normalizedCapacity
        protectedCapacity = normalizedCapacity > Int.max - 96 ? Int.max : normalizedCapacity + 96
        ordinaryCapacity = max(normalizedCapacity, protectedCapacity - 32)
    }

    var isFinished: Bool {
        lock.withLock { finished && inputs.isEmpty }
    }

    var count: Int {
        lock.withLock { inputs.count }
    }

    func append(_ input: NativeNVSTInput) -> Bool {
        lock.withLock {
            guard !finished else { return false }
            if coalesce(input) { return true }
            makeReservedCapacityIfNeeded(for: input)
            if inputs.count >= capacity {
                if let staleIndex = inputs.indices.first(where: {
                    Self.isLossy(inputs[$0]) && !isProtectedAbsoluteMove(at: $0) && !isProspectiveAbsoluteButtonPair(at: $0, incoming: input)
                }) {
                    inputs.remove(at: staleIndex)
                } else if Self.isNeutralizing(input), let pressIndex = inputs.firstIndex(where: Self.isNonNeutralButtonOrKeyPress) {
                    inputs.remove(at: pressIndex)
                } else if Self.isNeutralizing(input) {
                    inputs.removeFirst()
                } else if (!Self.isLossy(input) || Self.isAbsoluteMove(input)),
                          inputs.count < capacityLimit(for: input) {
                    inputs.append(input)
                    return true
                } else {
                    return false
                }
            }
            inputs.append(input)
            return true
        }
    }

    func removeFirst() -> NativeNVSTInput? {
        lock.withLock {
            guard !inputs.isEmpty else { return nil }
            return inputs.removeFirst()
        }
    }

    func finish(discardingStaleInput: Bool) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            if discardingStaleInput {
                let staleIndices = inputs.indices.filter { Self.isLossy(inputs[$0]) && !isProtectedAbsoluteMove(at: $0) }
                for index in staleIndices.reversed() { inputs.remove(at: index) }
            } else {
                inputs.removeAll(keepingCapacity: false)
            }
        }
    }

    private func coalesce(_ input: NativeNVSTInput) -> Bool {
        guard let last = inputs.last else { return false }
        switch (last, input) {
        case (.absoluteMove, .absoluteMove):
            inputs[inputs.count - 1] = input
            return true
        case (.event(.mouse(.moved(let oldDeviceID, let oldX, let oldY, _))),
              .event(.mouse(.moved(let newDeviceID, let newX, let newY, let timestamp)))) where oldDeviceID == newDeviceID:
            guard let deltaX = Self.sum(oldX, newX), let deltaY = Self.sum(oldY, newY) else { return false }
            inputs[inputs.count - 1] = .event(.mouse(.moved(
                deviceID: newDeviceID,
                deltaX: deltaX,
                deltaY: deltaY,
                timestamp: timestamp
            )))
            return true
        case (.event(.mouse(.wheel(let oldDeviceID, let oldDelta, _))),
              .event(.mouse(.wheel(let newDeviceID, let newDelta, let timestamp))))
            where oldDeviceID == newDeviceID && (oldDelta > 0) == (newDelta > 0):
            guard let delta = Self.sum(oldDelta, newDelta) else { return false }
            inputs[inputs.count - 1] = .event(.mouse(.wheel(deviceID: newDeviceID, delta: delta, timestamp: timestamp)))
            return true
        case (.event(.gamepad(let oldState)), .event(.gamepad(let newState)))
            where oldState.playerIndex == newState.playerIndex && oldState.deviceID == newState.deviceID &&
                oldState.buttons == newState.buttons &&
                !Self.isNeutralizing(last) && !Self.isNeutralizing(input):
            inputs[inputs.count - 1] = input
            return true
        default:
            return false
        }
    }

    private static func isLossy(_ input: NativeNVSTInput) -> Bool {
        switch input {
        case .absoluteMove, .event(.mouse(.moved)):
            return true
        case .event(.gamepad(let state)):
            return state.buttons.isEmpty && !isNeutralizing(input)
        case .event:
            return false
        }
    }

    private static func isAbsoluteMove(_ input: NativeNVSTInput) -> Bool {
        if case .absoluteMove = input { return true }
        return false
    }

    private func capacityLimit(for input: NativeNVSTInput) -> Int {
        if Self.isAbsoluteMove(input) { return protectedCapacity }
        if case .event(.mouse(.wheel)) = input { return max(ordinaryCapacity, protectedCapacity - 10) }
        if case .event(.mouse(.button)) = input, inputs.last.map(Self.isAbsoluteMove) == true { return protectedCapacity }
        return ordinaryCapacity
    }

    private func makeReservedCapacityIfNeeded(for input: NativeNVSTInput) {
        guard inputs.count >= capacityLimit(for: input) else { return }
        let needsAbsoluteSlot = Self.isAbsoluteMove(input)
        let needsButtonSlot = inputs.last.map(Self.isAbsoluteMove) == true && {
            if case .event(.mouse(.button)) = input { return true }
            return false
        }()
        guard needsAbsoluteSlot || needsButtonSlot else { return }
        guard let pairStart = inputs.indices.first(where: {
            $0 + 1 < inputs.count - (needsButtonSlot ? 1 : 0) && isEvictableAbsolutePressPair(at: $0)
        }) else { return }
        inputs.remove(at: pairStart + 1)
        inputs.remove(at: pairStart)
    }

    private func isEvictableAbsolutePressPair(at index: Int) -> Bool {
        guard isProtectedAbsoluteMove(at: index) else { return false }
        guard case .event(.mouse(.button(_, _, let isPressed, _))) = inputs[index + 1] else { return false }
        return isPressed
    }

    private static func isNeutralizing(_ input: NativeNVSTInput) -> Bool {
        guard case .event(let event) = input else { return false }
        return NativeNVSTInputDispatcher.isNeutralizing(event)
    }

    private static func isNonNeutralButtonOrKeyPress(_ input: NativeNVSTInput) -> Bool {
        switch input {
        case .event(.keyboard(let event)):
            return event.isPressed
        case .event(.mouse(.button(_, _, let isPressed, _))):
            return isPressed
        case .event(.gamepad(let state)):
            return !state.buttons.isEmpty
        default:
            return false
        }
    }

    private func isProtectedAbsoluteMove(at index: Int) -> Bool {
        guard case .absoluteMove = inputs[index], inputs.indices.contains(index + 1) else { return false }
        guard case .event(.mouse(.button)) = inputs[index + 1] else { return false }
        return true
    }

    private func isProspectiveAbsoluteButtonPair(at index: Int, incoming: NativeNVSTInput) -> Bool {
        guard index == inputs.count - 1, case .absoluteMove = inputs[index] else { return false }
        guard case .event(.mouse(.button)) = incoming else { return false }
        return true
    }

    private static func sum(_ lhs: Int16, _ rhs: Int16) -> Int16? {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }
}
