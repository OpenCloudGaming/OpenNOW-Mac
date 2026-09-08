import Foundation
import Testing
@testable import OpenNOW

// What the path does with the seat's own verdict. These pin the bug the notification was being
// logged and then dropped for: a seat that ends a session was answered with in-place recovery,
// because nothing told `NativeNVSTRecoveryPolicy` the session was over. A title quitting to the
// desktop cost a full budget of CloudMatch resume attempts and then reported a stall.

private func seatTermination(result: UInt32) -> NvstSeatTermination {
    NvstSeatTermination(result: result, payload: Data([0x80, 0x03, 0x00, 0x00]))
}

@Test func aSeatCommandedEndRefusesRecovery() {
    let results: [UInt32] = [
        0x8003_0014, // NVST_DISCONN_SERVER_TERMINATED_GAME_PROCESS_EXITED
        0x8003_0023, // NVST_DISCONN_SERVER_TERMINATED_CLOSED
        0x8003_000b, // NVST_DISCONN_OPERATOR_COMMANDED_TERMINATION
        0x8003_000a, // NVST_DISCONN_CLIENT_RECONNECT_TIMEOUT
        0x8004_000b, // NVST_NETERR_SERVER_TERMINATED_UNINTENDED
    ]

    for result in results {
        let termination = seatTermination(result: result).sessionTermination
        #expect(!termination.permitsSameSessionRecovery)
        #expect(!NativeNVSTRecoveryPolicy.permitsRecovery(.sessionTerminated(termination)))
        #expect(!termination.isResumable)
        #expect(!termination.isSessionAlive)
    }
}

/// The seat's reason has to survive into the report: "the cloud server ended the session" plus
/// NVIDIA's own name for it is the diagnosis, where a stall message is a guess that happens to be
/// about the same three seconds.
@Test func aSeatCommandedEndCarriesTheSeatsReason() {
    let termination = seatTermination(result: 0x8003_0014).sessionTermination

    #expect(!termination.isPause)
    #expect(termination.message.contains("NVST_DISCONN_SERVER_TERMINATED_GAME_PROCESS_EXITED"))
    #expect(termination.message.contains("0x80030014"))
    #expect(termination.reason.resultName == "NVST_DISCONN_SERVER_TERMINATED_GAME_PROCESS_EXITED")
    #expect(termination.extendedResult.name == "NVST_DISCONN_SERVER_TERMINATED_GAME_PROCESS_EXITED")
}

/// A pause is reported through the same command, and it is the one verdict that must leave the
/// cloud session alive: `.paused` is what keeps `finishSession` from stopping it.
@Test func aSessionPauseStaysResumableAndIsNotAnEnd() {
    let termination = seatTermination(result: NvstSeatTermination.sessionPauseResult).sessionTermination

    #expect(termination.isPause)
    #expect(termination.isResumable)
    #expect(termination.isSessionAlive)
    #expect(!NativeNVSTRecoveryPolicy.permitsRecovery(.sessionTerminated(termination)))
    #expect(termination.message.contains("paused"))
}

/// An unnamed result is still the seat ending the session. Falling back to "recoverable" for a code
/// outside the recovered table would reintroduce the loop on the first seat that reports one.
@Test func anUnnamedResultStillEndsTheSession() {
    let termination = seatTermination(result: 0x8003_00ff).sessionTermination

    #expect(!termination.permitsSameSessionRecovery)
    #expect(!termination.isPause)
    #expect(termination.message.contains("0x800300ff"))
}

/// The transport's own verdict on a network-class failure is untouched by this: a link that dropped
/// without the seat saying anything is still worth one bounded series of reconnects.
@Test func aTransientTransportFailureStillPermitsRecovery() {
    let failure = NativeNVSTTransportFailure(
        message: "The NVST RTSPS control connection is closed.",
        result: NativeNVSTTerminationValue(code: 0, name: "NVB_R_NETWORK_ERROR"),
        recoveryClassification: .transientNetwork
    )

    #expect(NativeNVSTRecoveryPolicy.permitsRecovery(.transportFailed(failure)))
}
