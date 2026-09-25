import Foundation
import Testing
@testable import OpenNOW

/// The browser guest's control surface: newline-delimited JSON the web page parses directly. The
/// decoder config rides it too, base64-encoded, so this covers the framing the page relies on.
@Suite struct RemoteCoOpBrowserProtocolTests {
    @Test func controlMessagesRoundTrip() throws {
        let messages: [RemoteCoOpBrowserControlMessage] = [
            .join(token: "token.value", displayName: "Guest", participantID: nil, reconnectToken: nil),
            .joined(OPNRemoteCoOpParticipant(displayName: "Guest", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 2)),
            .state(OPNRemoteCoOpParticipant(displayName: "Guest", role: .guest, connectionState: .waitingForApproval)),
            .config(avcC: Data([1, 100, 0, 31, 0xFF, 0xE1]), width: 1920, height: 1080),
            .error("no slot free")
        ]
        for message in messages {
            var buffer = RemoteCoOpBrowserControlCodec.encode(message)
            let decoded = RemoteCoOpBrowserControlCodec.decode(from: &buffer)
            #expect(decoded == [message])
            #expect(buffer.isEmpty)
        }
    }

    @Test func configCarriesTheAvcCRecord() throws {
        let avcC = Data((0..<30).map { UInt8($0) })
        let message = RemoteCoOpBrowserControlMessage.config(avcC: avcC, width: 1280, height: 720)
        #expect(message.kind == .config)
        #expect(message.avcC == avcC.base64EncodedString())
        #expect(try #require(message.avcC.flatMap { Data(base64Encoded: $0) }) == avcC)
    }

    @Test func decodeHandlesSplitAndMultipleLines() {
        let first = RemoteCoOpBrowserControlCodec.encode(.join(token: "a", displayName: "One", participantID: nil, reconnectToken: nil))
        let second = RemoteCoOpBrowserControlCodec.encode(.error("two"))
        var combined = first + second

        // A read cut mid-message must leave the partial line for the next read rather than drop it.
        var partial = Data(combined.prefix(5))
        #expect(RemoteCoOpBrowserControlCodec.decode(from: &partial).isEmpty)
        partial.append(contentsOf: combined.dropFirst(5))
        let messages = RemoteCoOpBrowserControlCodec.decode(from: &partial)
        #expect(messages.count == 2)
        #expect(messages[0].kind == .join)
        #expect(messages[1].kind == .error)
        combined.removeAll()
    }
}
