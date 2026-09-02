//
//  RemoteCoOpInputLatencyMeasurementTests.swift
//  OpenNOW
//
//  Measures the guest-to-host input path over a real WebRTC data channel, because reasoning about it
//  from the code was wrong in both directions more than once.
//
//  Both peers share one process so send and arrival come from the same monotonic clock; across two
//  machines that subtraction is meaningless, which is why the shipped telemetry reports host-local
//  routing time and the guest's ICE round-trip separately. ICE nominates loopback, so this is the
//  software floor - real latency is this plus the route's round-trip.
//
//  Two depths: `LoopbackPeerPair` stops at the host peer's `receiveInput`, and
//  `LoopbackControllerHarness` goes through the real controller to `forwardInput`, where the native
//  transport hands input to `NativeNVSTInputDispatcher`. Only the second contains the scheduler.
//

import Foundation
import Testing
@testable import OpenNOW

/// Deltas are paired by index because a routed `UserInputEvent` does not preserve the guest's send
/// time. That is only valid with no loss and no reordering, so the tests check both first.
private actor InputLatencyRecorder {
    private(set) var arrivalNanoseconds: [UInt64] = []
    private(set) var sequenceNumbers: [UInt64] = []

    func recordPacket(_ packet: OPNRemoteCoOpInputPacket) {
        arrivalNanoseconds.append(DispatchTime.now().uptimeNanoseconds)
        sequenceNumbers.append(packet.sequenceNumber)
    }

    func recordArrival() {
        arrivalNanoseconds.append(DispatchTime.now().uptimeNanoseconds)
    }

    func reset() {
        arrivalNanoseconds.removeAll()
        sequenceNumbers.removeAll()
    }
}

/// Send instants, kept on the sending side so the recorder stays free of the pairing logic.
private final class SendLog: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: [UInt64] = []

    func note() {
        lock.lock()
        nanoseconds.append(DispatchTime.now().uptimeNanoseconds)
        lock.unlock()
    }

    var all: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return nanoseconds
    }

    func reset() {
        lock.lock()
        nanoseconds.removeAll()
        lock.unlock()
    }
}

private enum LatencyStatistics {
    /// Milliseconds per delivered packet, paired by index. Extra arrivals beyond the sends recorded
    /// (a redundant copy landing late, say) are ignored rather than paired with the wrong send.
    static func latenciesMilliseconds(sends: [UInt64], arrivals: [UInt64]) -> [Double] {
        zip(sends, arrivals).compactMap { send, arrival in
            guard arrival >= send else { return nil }
            return Double(arrival - send) / 1_000_000
        }
    }

    static func percentile(_ samples: [Double], _ fraction: Double) -> Double {
        guard !samples.isEmpty else { return -1 }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }

    static func report(_ label: String, _ samples: [Double], sent: Int) -> String {
        """
        [remote-coop input latency] \(label)
          delivered:  \(samples.count)/\(sent)
          median:     \(String(format: "%.3f", percentile(samples, 0.5))) ms
          p95:        \(String(format: "%.3f", percentile(samples, 0.95))) ms
          p99:        \(String(format: "%.3f", percentile(samples, 0.99))) ms
          worst:      \(String(format: "%.3f", percentile(samples, 1))) ms
        """
    }
}

/// Ferries signaling between the peers directly, which is the real topology: the native transport
/// carries offers and candidates over its own socket, with no broker.
private final class LoopbackPeerPair: @unchecked Sendable {
    let hostPeer: OPNRemoteCoOpWebRTCHostPeer
    let guestPeer: OPNRemoteCoOpNativeGuestPeer
    let recorder = InputLatencyRecorder()
    let sendLog = SendLog()

    init(participantID: UUID, latencyMode: OPNRemoteCoOpLatencyMode) {
        // `.directOnly` so no STUN server is contacted: the peers are on the same machine, and a
        // measurement that depends on reaching Google is not a measurement.
        let configuration = OPNRemoteCoOpNetworkConfiguration(transportMode: .directOnly, latencyMode: latencyMode)
        let guestPeer = OPNRemoteCoOpNativeGuestPeer(participantID: participantID)
        let recorder = self.recorder
        let callbacks = OPNRemoteCoOpHostPeerCallbacks(
            sendSignal: { signal in try? await guestPeer.handle(signal) },
            receiveInput: { packet in await recorder.recordPacket(packet) }
        )
        hostPeer = OPNRemoteCoOpWebRTCHostPeer(
            participantID: participantID,
            networkConfiguration: configuration,
            qualityPreset: .p1080f60,
            latencyMode: latencyMode,
            callbacks: callbacks
        )
        self.guestPeer = guestPeer
        let hostPeer = self.hostPeer
        guestPeer.onSignal = { signal in try? await hostPeer.apply(signal) }
        try? guestPeer.start(networkConfiguration: configuration)
    }

    func send(_ packet: OPNRemoteCoOpInputPacket) {
        sendLog.note()
        guestPeer.sendInput(packet)
    }

    func close() async {
        guestPeer.close()
        await hostPeer.close()
    }
}

/// The same pair through the real controller, so the measured path includes the scheduler.
private final class LoopbackControllerHarness: @unchecked Sendable {
    let participantID = UUID()
    let recorder = InputLatencyRecorder()
    let sendLog = SendLog()
    private let signaling = OPNInProcessRemoteCoOpSignalingSession()
    private let hostSession: OPNRemoteCoOpHostSession
    private let coordinator: OPNRemoteCoOpHostCoordinator
    private var controller: OPNRemoteCoOpHostPeerController?
    private var guestPeer: OPNRemoteCoOpNativeGuestPeer?
    private var signalPump: Task<Void, Never>?

    init(latencyMode: OPNRemoteCoOpLatencyMode) {
        hostSession = OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(
            isEnabled: true,
            reservedGuestSlots: 1,
            latencyMode: latencyMode,
            requireHostApproval: true
        ))
        coordinator = OPNRemoteCoOpHostCoordinator(hostSession: hostSession, signaling: signaling)
    }

    func start(latencyMode: OPNRemoteCoOpLatencyMode, timeout: Duration) async throws -> Bool {
        let configuration = OPNRemoteCoOpNetworkConfiguration(transportMode: .directOnly, latencyMode: latencyMode)
        let guestPeer = OPNRemoteCoOpNativeGuestPeer(participantID: participantID)
        try guestPeer.start(networkConfiguration: configuration)
        self.guestPeer = guestPeer

        let recorder = self.recorder
        let controller = OPNRemoteCoOpHostPeerController(
            signaling: signaling,
            coordinator: coordinator,
            networkConfiguration: configuration,
            qualityPreset: .p1080f60,
            latencyMode: latencyMode,
            // The measured endpoint. In the app this closure reaches `NativeNVSTInputDispatcher`.
            forwardInput: { _ in await recorder.recordArrival() }
        )
        self.controller = controller

        // The host's offer and candidates travel out as *commands* - `events()` is the guest-to-host
        // direction and never carries them, which is why an earlier version of this harness sat waiting
        // for a channel that was never negotiated. The guest's answer comes back in through
        // `receiveSignal`. Same two directions the native server carries in production.
        let commands = signaling.commands()
        signalPump = Task {
            for await command in commands {
                guard case .peerSignal(_, let signal) = command else { continue }
                try? await guestPeer.handle(signal)
            }
        }
        let participantID = self.participantID
        guestPeer.onSignal = { signal in
            try? await controller.receiveSignal(participantID: participantID, signal: signal)
        }

        let invite = try await coordinator.startInvite(lifetimeSeconds: 120)
        _ = await coordinator.handle(.guestJoinRequested(participantID: participantID, inviteToken: invite.token, displayName: "Latency Probe"))
        let approved = try await coordinator.approveParticipant(participantID)
        try await controller.sync(participants: [approved])

        let deadline = ContinuousClock.now + timeout
        var sequenceNumber: UInt64 = 0
        while ContinuousClock.now < deadline {
            sequenceNumber += 1
            guestPeer.sendInput(OPNRemoteCoOpInputPacket(participantID: participantID, sequenceNumber: sequenceNumber, leftStickX: Float(sequenceNumber % 50) / 50))
            try? await Task.sleep(for: .milliseconds(25))
            if await !recorder.arrivalNanoseconds.isEmpty { return true }
        }
        return false
    }

    func send(_ packet: OPNRemoteCoOpInputPacket) {
        sendLog.note()
        guestPeer?.sendInput(packet)
    }

    func close() async {
        signalPump?.cancel()
        guestPeer?.close()
        await controller?.removeAll()
        await signaling.close()
    }
}

@Suite("Remote Co-Op input latency", .serialized)
struct RemoteCoOpInputLatencyMeasurementTests {
    private static let connectTimeout = Duration.seconds(20)

    /// Sends probes until one arrives, so measurement starts only once DTLS and SCTP are up. Returns
    /// the highest sequence number used, so measured packets can be numbered after it.
    private static func waitForOpenInputChannel(_ pair: LoopbackPeerPair, participantID: UUID) async -> UInt64? {
        let deadline = ContinuousClock.now + connectTimeout
        var sequenceNumber: UInt64 = 0
        while ContinuousClock.now < deadline {
            sequenceNumber += 1
            pair.guestPeer.sendInput(OPNRemoteCoOpInputPacket(participantID: participantID, sequenceNumber: sequenceNumber))
            try? await Task.sleep(for: .milliseconds(25))
            if await !pair.recorder.arrivalNanoseconds.isEmpty { return sequenceNumber }
        }
        return nil
    }

    @Test("guest input reaches the host peer well inside the millisecond budget")
    func guestInputLatencyOverRealDataChannel() async throws {
        let participantID = UUID()
        let pair = LoopbackPeerPair(participantID: participantID, latencyMode: .lowLatency)
        defer { Task { await pair.close() } }

        try await pair.hostPeer.start()
        guard let probeSequenceNumber = await Self.waitForOpenInputChannel(pair, participantID: participantID) else {
            // A sandbox that blocks even loopback UDP is an environment problem, not a regression, and
            // failing here would say nothing about the code.
            Issue.record("Input data channel never opened; cannot measure. Check whether loopback UDP is available.")
            return
        }
        await pair.recorder.reset()
        pair.sendLog.reset()

        // Spaced at 4 ms: a realistic pad rate, and slow enough that each packet is timed on its own
        // rather than measuring how fast a burst drains.
        let sampleCount = 120
        var sequenceNumber = probeSequenceNumber
        for _ in 0..<sampleCount {
            sequenceNumber += 1
            pair.send(OPNRemoteCoOpInputPacket(
                participantID: participantID,
                sequenceNumber: sequenceNumber,
                buttons: GamepadButtons(rawValue: UInt32(sequenceNumber % 8)),
                leftStickX: Float(sequenceNumber % 100) / 100
            ))
            try? await Task.sleep(for: .milliseconds(4))
        }
        try? await Task.sleep(for: .milliseconds(500))

        let arrived = await pair.recorder.sequenceNumbers
        let outOfOrder = zip(arrived, arrived.dropFirst()).count { $0.1 <= $0.0 }
        let samples = LatencyStatistics.latenciesMilliseconds(sends: pair.sendLog.all, arrivals: await pair.recorder.arrivalNanoseconds)
        print(LatencyStatistics.report("guest sendInput -> host peer receiveInput, loopback ICE", samples, sent: sampleCount))

        // Index pairing is only sound with no loss and no reordering, so both are checked here rather
        // than assumed. The channel is unordered with no retransmits by design, so a stray loss is
        // legitimate - losing a tenth of the packets on loopback would not be.
        #expect(arrived.count >= sampleCount * 9 / 10, "delivered \(arrived.count) of \(sampleCount)")
        #expect(outOfOrder == 0, "\(outOfOrder) out-of-order arrivals, which invalidates index pairing")
        // Median, not the tail: alone this suite sees a p99 under 1 ms, but under full-suite load the
        // same code has hit 6.5 ms - indistinguishable from the 6.9 ms the old coalescing timer gave.
        // The median discriminates, moving from 6.48 ms before this branch to 0.77 ms after.
        #expect(LatencyStatistics.percentile(samples, 0.5) < 2.0)
    }

    /// The number that actually answers the question, because this path contains the scheduler.
    @Test("guest input reaches the host's input dispatcher inside the budget")
    func guestInputLatencyThroughHostController() async throws {
        for latencyMode in OPNRemoteCoOpLatencyMode.allCases {
            let harness = LoopbackControllerHarness(latencyMode: latencyMode)
            guard try await harness.start(latencyMode: latencyMode, timeout: Self.connectTimeout) else {
                Issue.record("Input channel never opened in \(latencyMode.rawValue) mode; cannot measure.")
                await harness.close()
                continue
            }
            await harness.recorder.reset()
            harness.sendLog.reset()

            let sampleCount = 100
            for index in 0..<sampleCount {
                harness.send(OPNRemoteCoOpInputPacket(
                    participantID: harness.participantID,
                    sequenceNumber: UInt64(100_000 + index),
                    // Analog-only movement with the buttons held constant. This is the exact traffic the
                    // old scheduler parked on its 4 ms timer, so it is the traffic worth timing.
                    buttons: [.south],
                    leftStickX: Float(index % 100) / 100
                ))
                try? await Task.sleep(for: .milliseconds(4))
            }
            try? await Task.sleep(for: .milliseconds(500))

            let samples = LatencyStatistics.latenciesMilliseconds(sends: harness.sendLog.all, arrivals: await harness.recorder.arrivalNanoseconds)
            print(LatencyStatistics.report("guest sendInput -> host forwardInput (\(latencyMode.rawValue)), loopback ICE", samples, sent: sampleCount))

            #expect(samples.count >= sampleCount * 9 / 10, "\(latencyMode.rawValue): delivered \(samples.count) of \(sampleCount)")
            // Median only, for the reason given above: a scheduler that holds analog packets on a
            // timer lands here at the median, which is what makes the median the discriminating
            // statistic and the tail merely a report on how busy the machine was.
            #expect(LatencyStatistics.percentile(samples, 0.5) < 2.0, "\(latencyMode.rawValue) median")
            await harness.close()
        }
    }
}
