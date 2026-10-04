import Foundation
import Testing
@testable import OpenNOW

/// The seat allows one live session per device and this client reports one device hash for the whole
/// Mac, so each account has to stream under its own - derived from the machine's, so it is stable.
@Suite struct OPNDeviceIdentityTests {
    private func account(_ subject: String, provider: String = "nvidia") throws -> OPNAccountID {
        try #require(OPNAccountID(providerIdpId: provider, vendorSubject: subject))
    }

    @Test func eachAccountStreamsUnderItsOwnDevice() throws {
        let first = try account("user-a")
        let second = try account("user-b")

        let firstDevice = OPNDeviceIdentity.cloudmatchDeviceId(accountID: first)

        #expect(firstDevice == OPNDeviceIdentity.cloudmatchDeviceId(accountID: first), "the same account has to keep one device across launches")
        #expect(firstDevice != OPNDeviceIdentity.cloudmatchDeviceId(accountID: second))
        #expect(firstDevice != OPNDeviceIdentity.stableCloudmatchDeviceId(), "the machine's own id would put both accounts back on one device")
    }

    /// The same address under two providers is two accounts, so it is two devices as well.
    @Test func theSameSubjectUnderTwoProvidersIsTwoDevices() throws {
        let jarvis = try account("player@example.com")
        let starfleet = try account("player@example.com", provider: "starfleet")

        #expect(OPNDeviceIdentity.cloudmatchDeviceId(accountID: jarvis) != OPNDeviceIdentity.cloudmatchDeviceId(accountID: starfleet))
    }

    /// The seat expects this field to look like a device id.
    @Test func theAccountDeviceLooksLikeADeviceId() throws {
        let device = OPNDeviceIdentity.cloudmatchDeviceId(accountID: try account("user-a"))

        #expect(device.count == 36)
        #expect(device.filter { $0 == "-" }.count == 4)
        #expect(device.allSatisfy { $0.isHexDigit || $0 == "-" })
    }
}
