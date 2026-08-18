import Foundation
import Testing
@testable import OpenNOW

private enum RuntimeCallbackTestError: Error {
    case failed
}

private final class HapticRecordCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [NativeNVSTHapticCommand] = []

    func append(player: UInt16, low: UInt16, high: UInt16, duration: UInt16) {
        lock.lock()
        records.append(NativeNVSTHapticCommand(playerIndex: Int(player), lowFrequency: low, highFrequency: high, durationMilliseconds: duration))
        lock.unlock()
    }

    func snapshot() -> [NativeNVSTHapticCommand] {
        lock.lock()
        let records = self.records
        lock.unlock()
        return records
    }
}

private final class AuthResponseBuffer: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<CChar>
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        pointer = .allocate(capacity: capacity)
        pointer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        pointer.deallocate()
    }

    var string: String { String(cString: pointer) }
}

private final class CallbackInvocationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false

    func record() {
        lock.lock()
        called = true
        lock.unlock()
    }

    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return called
    }
}

private func collectNativeHapticRecord(_ context: UnsafeMutableRawPointer?, _ player: UInt16, _ low: UInt16, _ high: UInt16, _ duration: UInt16) {
    guard let context else { return }
    Unmanaged<HapticRecordCollector>.fromOpaque(context).takeUnretainedValue().append(player: player, low: low, high: high, duration: duration)
}

private typealias NativeHapticTestHandler = @convention(c) (UnsafeMutableRawPointer?, UInt16, UInt16, UInt16, UInt16) -> Void

@_silgen_name("OpenNOWNativeNVSTGeronimoDecodeHapticCallbackData")
private func decodeNativeHapticCallbackData(_ bytes: UnsafePointer<UInt8>?, _ count: Int, _ handler: NativeHapticTestHandler?, _ context: UnsafeMutableRawPointer?) -> Int32

@Test func nativeHapticDecoderCopiesRemappedSubtypeRecords() {
    let collector = HapticRecordCollector()
    let context = Unmanaged.passUnretained(collector).toOpaque()
    var subtypeTwo = [UInt8](repeating: 0, count: 0x26)
    subtypeTwo.write(UInt32(0x14), at: 0)
    subtypeTwo.write(UInt32(2), at: 0x10)
    subtypeTwo.write(UInt16(16), at: 0x14)
    subtypeTwo.write(UInt16(2), at: 0x16)
    subtypeTwo.write(UInt16(1_000), at: 0x18)
    subtypeTwo.write(UInt16(2_000), at: 0x1a)
    subtypeTwo.write(UInt16(300), at: 0x1c)
    subtypeTwo.write(UInt16(0), at: 0x1e)
    subtypeTwo.write(UInt16(3_000), at: 0x20)
    subtypeTwo.write(UInt16(4_000), at: 0x22)
    subtypeTwo.write(UInt16(0), at: 0x24)

    let decoded = subtypeTwo.withUnsafeBufferPointer {
        decodeNativeHapticCallbackData($0.baseAddress, $0.count, collectNativeHapticRecord, context)
    }

    #expect(decoded == 2)
    #expect(collector.snapshot() == [
        NativeNVSTHapticCommand(playerIndex: 2, lowFrequency: 1_000, highFrequency: 2_000, durationMilliseconds: 300),
        NativeNVSTHapticCommand(playerIndex: 0, lowFrequency: 3_000, highFrequency: 4_000, durationMilliseconds: 1_000),
    ])

    var subtypeOne = [UInt8](repeating: 0, count: 0x1c)
    subtypeOne.write(UInt32(0x14), at: 0)
    subtypeOne.write(UInt32(1), at: 0x10)
    subtypeOne.write(UInt16(6), at: 0x14)
    subtypeOne.write(UInt16(3), at: 0x16)
    subtypeOne.write(UInt16(5_000), at: 0x18)
    subtypeOne.write(UInt16(6_000), at: 0x1a)
    let subtypeOneDecoded = subtypeOne.withUnsafeBufferPointer {
        decodeNativeHapticCallbackData($0.baseAddress, $0.count, collectNativeHapticRecord, context)
    }
    #expect(subtypeOneDecoded == 1)
    #expect(collector.snapshot().last == NativeNVSTHapticCommand(playerIndex: 3, lowFrequency: 5_000, highFrequency: 6_000, durationMilliseconds: 1_000))
}

@Test func nativeHapticRoutingUsesHandlesAndSafeDefault() {
    let command = NativeNVSTHapticCommand(playerIndex: 1, lowFrequency: 10, highFrequency: 20, durationMilliseconds: 50)
    #expect(NativeNVSTHapticRouter.routes(for: command, supportsHandles: true) == [
        NativeNVSTHapticRoute(locality: .leftHandle, intensity: 10),
        NativeNVSTHapticRoute(locality: .rightHandle, intensity: 20),
    ])
    #expect(NativeNVSTHapticRouter.routes(for: command, supportsHandles: false) == [
        NativeNVSTHapticRoute(locality: .default, intensity: 20),
    ])
}

@Test func nativeGamepadTopologyTracksDisconnectAndGlobalFeatureState() {
    let connected = NativeWebRTCGamepadTopology(playerIndices: [0, 2], hapticPlayerIndices: [2])
    #expect(connected.connectedPlayerBitmap == 0b0101)
    #expect(connected.hapticPlayerBitmap == 0b0100)
    #expect(connected.hapticsEnabled)

    let disconnectedHapticController = NativeWebRTCGamepadTopology(playerIndices: [0], hapticPlayerIndices: [2])
    #expect(disconnectedHapticController.connectedPlayerBitmap == 0b0001)
    #expect(disconnectedHapticController.hapticPlayerBitmap == 0)
    #expect(!disconnectedHapticController.hapticsEnabled)

    let disconnectedAll = NativeWebRTCGamepadTopology(playerIndices: [])
    #expect(disconnectedAll.connectedPlayerBitmap == 0)
    #expect(disconnectedAll.registrationBitmap == 0)
}

@Test func nativeAuthRefreshCopiesSuccessAndEnforcesBounds() {
    let coordinator = NativeNVSTAuthRefreshCoordinator(expectedAuthType: 9) { authType in
        #expect(authType == 9)
        return "abcdefghijklmnopqrstuvwxyz"
    }
    let response = AuthResponseBuffer(capacity: 8)
    coordinator.copyRefreshedToken(authType: 9, response: response.pointer, capacity: response.capacity)
    #expect(response.string == "abcdefg")
    #expect(response.pointer[7] == 0)
}

@Test func nativeAuthRefreshReturnsEmptyOnFailureAndAuthMismatch() {
    let coordinator = NativeNVSTAuthRefreshCoordinator(expectedAuthType: 8) { _ in throw RuntimeCallbackTestError.failed }
    let failure = AuthResponseBuffer(capacity: 32)
    coordinator.copyRefreshedToken(authType: 8, response: failure.pointer, capacity: failure.capacity)
    #expect(failure.string.isEmpty)

    let mismatch = AuthResponseBuffer(capacity: 32)
    coordinator.copyRefreshedToken(authType: 9, response: mismatch.pointer, capacity: mismatch.capacity)
    #expect(mismatch.string.isEmpty)
    #expect(NativeNVSTAuthRefreshCoordinator.authType(for: "JWT") == 8)
    #expect(NativeNVSTAuthRefreshCoordinator.authType(for: "JWT_GFN") == 9)
    var session = OPNAuthSession()
    session.accessToken = "access"
    session.idToken = "identity"
    #expect(NativeNVSTAuthRefreshCoordinator.token(from: session, authType: 8) == "identity")
    #expect(NativeNVSTAuthRefreshCoordinator.token(from: session, authType: 9) == "access")
}

@Test func nativeAuthRefreshDoesNotStartWithoutVerifiedWritableCapacity() {
    let tracker = CallbackInvocationTracker()
    let coordinator = NativeNVSTAuthRefreshCoordinator(expectedAuthType: 9) { _ in
        tracker.record()
        return "must-not-be-written"
    }
    let response = AuthResponseBuffer(capacity: 1)

    coordinator.copyRefreshedToken(authType: 9, response: response.pointer, capacity: response.capacity)

    #expect(!tracker.wasCalled)
    #expect(response.pointer[0] == 0)
}

@Test func nativeStopCallbackFailurePropagates() async {
    let sink = NativeNVSTGeronimoEventSink(
        sessionId: "stop-failure-test",
        telemetryAttributes: [:],
        cursorVisibilityHandler: nil,
        terminationHandler: { _ in }
    )
    sink.beginStop()
    sink.handle(
        phase: 60,
        callbackType: 0,
        clientEvent: 0,
        notification: 0,
        resultCode: 101,
        resultName: "NVB_R_INVALID_PARAM",
        resumable: false,
        sessionAlive: false,
        reasonName: nil
    )

    do {
        try await sink.waitForStop(timeoutNanoseconds: 1_000_000_000)
        Issue.record("Expected the failed native stop callback to throw")
    } catch {
        #expect(error.localizedDescription.contains("101"))
    }
}

@Test func nativeStopCallbackTimeoutPropagates() async {
    let sink = NativeNVSTGeronimoEventSink(
        sessionId: "stop-timeout-test",
        telemetryAttributes: [:],
        cursorVisibilityHandler: nil,
        terminationHandler: { _ in }
    )
    sink.beginStop()

    do {
        try await sink.waitForStop(timeoutNanoseconds: 1_000_000)
        Issue.record("Expected the native stop callback wait to time out")
    } catch {
        #expect(error.localizedDescription == NativeNVSTBifrostTransport.geronimoStopTimeoutMessage)
    }
}

@Test func nativeAuthRefreshTimesOutAndCancelsWithoutBlockingMainActor() async {
    let timeoutCoordinator = NativeNVSTAuthRefreshCoordinator(expectedAuthType: 9, timeout: .milliseconds(20)) { _ in
        try await Task.sleep(for: .seconds(2))
        return "late-token"
    }
    let timeoutResponse = AuthResponseBuffer(capacity: 32)
    let clock = ContinuousClock()
    let start = clock.now
    timeoutCoordinator.copyRefreshedToken(authType: 9, response: timeoutResponse.pointer, capacity: timeoutResponse.capacity)
    #expect(timeoutResponse.string.isEmpty)
    #expect(start.duration(to: clock.now) < .seconds(1))

    let cancelCoordinator = NativeNVSTAuthRefreshCoordinator(expectedAuthType: 9) { _ in
        try await Task.sleep(for: .seconds(2))
        return "late-token"
    }
    let cancelResponse = AuthResponseBuffer(capacity: 32)
    let waiter = Task.detached {
        cancelCoordinator.copyRefreshedToken(authType: 9, response: cancelResponse.pointer, capacity: cancelResponse.capacity)
    }
    try? await Task.sleep(for: .milliseconds(20))
    cancelCoordinator.cancel()
    await waiter.value
    #expect(cancelResponse.string.isEmpty)
}

private extension Array where Element == UInt8 {
    mutating func write<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: value.littleEndian, toByteOffset: offset, as: T.self)
        }
    }
}
