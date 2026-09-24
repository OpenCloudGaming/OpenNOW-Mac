import Foundation
import Testing
@testable import OpenNOW

/// The split is positional, and a mistake in it does not fail loudly — media simply decrypts to
/// noise — so each field is pinned by offset, not just by shape.
@Suite struct NvstBundleSrtpKeysTests {
    private static let profile = NVSTSrtpProfile.aeadAes256Gcm8

    @Test func theExportedLengthCoversBothDirectionsOfKeysAndSalts() {
        // AEAD_AES_256_GCM is a 32-byte key with a 12-byte salt: (32 + 12) * 2 = 88.
        #expect(NvstBundleSrtpKeys.exportedLength(for: Self.profile) == 88)
    }

    @Test func eachFieldComesFromItsOwnSpanOfTheExport() throws {
        let exported = Data((0..<88).map { UInt8($0) })
        let keys = try NvstBundleSrtpKeys.split(exported, profile: Self.profile)
        #expect(keys.clientMasterKey == Data(0..<32))
        #expect(keys.serverMasterKey == Data(32..<64))
        #expect(keys.clientMasterSalt == Data(64..<76))
        #expect(keys.serverMasterSalt == Data(76..<88))
    }

    @Test func theTwoDirectionsNeverShareMaterial() throws {
        let keys = try NvstBundleSrtpKeys.split(Data(repeating: 0x5A, count: 88), profile: Self.profile)
        #expect(keys.clientMasterKey.count == 32)
        #expect(keys.clientMasterSalt.count == 12)
        // Same bytes in, but they must be distinct values taken from distinct offsets.
        let exported = Data((0..<88).map { UInt8($0) })
        let split = try NvstBundleSrtpKeys.split(exported, profile: Self.profile)
        #expect(split.clientMasterKey != split.serverMasterKey)
        #expect(split.clientMasterSalt != split.serverMasterSalt)
        _ = keys
    }

    @Test func aShortExportIsRejectedRatherThanTruncated() {
        let short = Data(repeating: 0, count: 87)
        #expect(throws: NvstBundleSrtpKeys.SplitError.wrongLength(expected: 88, actual: 87)) {
            try NvstBundleSrtpKeys.split(short, profile: Self.profile)
        }
    }
}
