import Foundation
import Testing
@testable import OpenNOW

/// D3: a filesystem path is bound to this Mac. Neither capture-library key may reach iCloud, and the
/// deny-list is what says so even though the keys sit outside every allowed prefix.
struct OPNCaptureSyncSettingsTests {
    @Test func captureFolderPathsAreDeniedAndNeverSyncable() {
        for library in OPNCaptureLibrary.allCases {
            let key = library.preferenceKey
            #expect(key.hasPrefix("OpenNOW.Capture."))
            #expect(OPNCloudSyncSettingsRegistry.isDenied(key))
            #expect(!OPNCloudSyncSettingsRegistry.isSyncable(key))
        }
    }

    @Test func theWholeCaptureNamespaceStaysLocal() {
        #expect(!OPNCloudSyncSettingsRegistry.isSyncable("OpenNOW.Capture.ScreenshotsDirectoryPath"))
        #expect(!OPNCloudSyncSettingsRegistry.isSyncable("OpenNOW.Capture.RecordingsDirectoryPath"))
        // A key a later build might add under the same namespace is covered by the deny-list entries
        // as long as it is named; this asserts the prefix itself is not in the allow-list.
        #expect(!OPNCloudSyncSettingsRegistry.allowedPrefixes.contains("OpenNOW.Capture."))
    }
}
