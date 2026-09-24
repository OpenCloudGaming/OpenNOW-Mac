import Foundation
import Testing
@testable import OpenNOW

/// The punch is what gives the bundle socket a route at the seat's front end. Its username is the
/// DESCRIBE remote ufrag — which ends in the seat's internal bundle port — plus our shared local
/// ufrag, and it must be a STUN Binding Request authenticated with the remote password.
@Suite struct NvstBundleNattPunchTests {
    @Test func theUsernameIsTheSeatUfragAndOurLocalUfrag() {
        #expect(NvstBundleNattPunch.username(remoteUfrag: "e503c1fe47999", localUfrag: "abcd") == "e503c1fe47999:abcd")
    }

    @Test func theRequestIsABindingRequestCarryingTheTransaction() throws {
        let transactionID = Data(repeating: 0x11, count: 12)
        let request = try #require(NvstBundleNattPunch.request(
            remoteUfrag: "e503c1fe47999",
            localUfrag: "abcd",
            remotePassword: Data("remote-pass".utf8),
            transactionID: transactionID
        ))
        #expect(request.count >= 20)
        #expect(request[request.startIndex] == 0x00)
        #expect(request[request.startIndex + 1] == 0x01)
        #expect(NvstStunHolePunch.bindingRequestTransactionID(request) == transactionID)
    }

    @Test func theIntegrityIsKeyedByTheRemotePassword() throws {
        let transactionID = Data(repeating: 0x22, count: 12)
        let withRemote = try #require(NvstBundleNattPunch.request(
            remoteUfrag: "e503c1fe47999", localUfrag: "abcd",
            remotePassword: Data("remote-pass".utf8), transactionID: transactionID
        ))
        let withWrong = try #require(NvstBundleNattPunch.request(
            remoteUfrag: "e503c1fe47999", localUfrag: "abcd",
            remotePassword: Data("not-the-password".utf8), transactionID: transactionID
        ))
        #expect(withRemote != withWrong)
    }

    @Test func transactionIdentifiersAreTwelveBytes() {
        #expect(NvstBundleNattPunch.transactionID().count == 12)
    }
}
