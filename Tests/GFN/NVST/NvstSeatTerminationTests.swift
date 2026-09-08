import Foundation
import Testing
@testable import OpenNOW

// The seat's `0x0109` termination notification. The bytes here are captured ones: the 8-byte
// notification is from a session whose title quit to desktop
// (`090108008003002300000202` in the 2026-09-01 log), and the 4-byte form is the shape the
// shorter sessions of the same day sent.

private func packet(_ hex: String) -> Data {
    var data = Data()
    var characters = hex.makeIterator()
    while let first = characters.next(), let second = characters.next() {
        data.append(UInt8(String([first, second]), radix: 16)!)
    }
    return data
}

private func terminationPacket(result: UInt32) -> Data {
    var payload: [UInt8] = [0x09, 0x01, 0x04, 0x00]
    payload.append(contentsOf: [
        UInt8((result >> 24) & 0xff), UInt8((result >> 16) & 0xff),
        UInt8((result >> 8) & 0xff), UInt8(result & 0xff)
    ])
    return Data(payload)
}

@Test func parsesTheCapturedEightByteTermination() throws {
    let command = try #require(NvstControlCommand.parse(packet("090108008003002300000202")).commands.first)
    let termination = try #require(NvstSeatTermination.parse(command))

    #expect(termination.result == 0x8003_0023)
    #expect(termination.resultName == "NVST_DISCONN_SERVER_TERMINATED_CLOSED")
    #expect(termination.payload.count == 8)
    #expect(!termination.isSessionPause)
    #expect(termination.summary.contains("NVST_DISCONN_SERVER_TERMINATED_CLOSED"))
    #expect(termination.summary.contains("0x80030023"))
    #expect(termination.summary.contains("len=8"))
}

@Test func parsesTheFourByteGameExitTermination() throws {
    let command = try #require(NvstControlCommand.parse(terminationPacket(result: 0x8003_0014)).commands.first)
    let termination = try #require(NvstSeatTermination.parse(command))

    #expect(termination.resultName == "NVST_DISCONN_SERVER_TERMINATED_GAME_PROCESS_EXITED")
    #expect(termination.payload.count == 4)
    #expect(!termination.isSessionPause)
}

/// A result outside the recovered table is still a termination: the seat's code space is not
/// closed, and an unnamed word must end the session rather than read as "nothing happened".
@Test func parsesAnUnnamedResult() throws {
    let command = try #require(NvstControlCommand.parse(terminationPacket(result: 0x8003_00ff)).commands.first)
    let termination = try #require(NvstSeatTermination.parse(command))

    #expect(termination.result == 0x8003_00ff)
    #expect(termination.resultName == nil)
    #expect(termination.summary.contains("0x800300ff"))
}

/// The pause arrives on the same command, so telling it apart is what keeps a paused cloud session
/// alive and resumable instead of being reported as an end.
@Test func recognisesTheSessionPause() throws {
    let command = try #require(NvstControlCommand.parse(terminationPacket(result: NvstSeatTermination.sessionPauseResult)).commands.first)
    let termination = try #require(NvstSeatTermination.parse(command))

    #expect(termination.isSessionPause)
    #expect(termination.resultName == "NVST_DISCONN_BIFROST_INITIATED_SESSION_PAUSE")
}

@Test func ignoresEveryOtherCommand() {
    var data = Data([0x01, 0x01, 0x02, 0x00, 0xaa, 0xbb])
    data.append(Data([0x0b, 0x01, 0x01, 0x00, 0xcc]))
    let commands = NvstControlCommand.parse(data).commands

    #expect(commands.count == 2)
    #expect(commands.allSatisfy { NvstSeatTermination.parse($0) == nil })
}

/// A reason word that did not arrive is not a termination. Guessing zero here would end a session
/// on a truncated control message.
@Test func ignoresATerminationShortOfItsReasonWord() {
    let command = NvstControlCommand(code: .termination, payload: Data([0x80, 0x03]))
    #expect(NvstSeatTermination.parse(command) == nil)
}
