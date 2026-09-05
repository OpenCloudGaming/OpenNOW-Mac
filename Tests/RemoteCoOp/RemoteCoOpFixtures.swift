//  Preference isolation and the media frames the Remote Co-Op suites are written against.
//

import Testing
import AudioUnit
import Foundation
import CoreVideo
@preconcurrency import WebRTC
@testable import OpenNOW

enum RemoteCoOpFixtures {
    static let preferenceDomain = "io.github.opencloudgaming.opennow"
    static let enabledKey = "OpenNOW.RemoteCoOp.Enabled"
    static let reservedGuestSlotsKey = "OpenNOW.RemoteCoOp.ReservedGuestSlots"
    static let latencyModeKey = "OpenNOW.RemoteCoOp.LatencyMode"
    static let lowLatencyDefaultMigrationVersionKey = "OpenNOW.RemoteCoOp.LowLatencyDefaultMigrationVersion"
    static let hostedGuestPageURLKey = "OpenNOW.RemoteCoOp.HostedGuestPageURL"

    static func withPreservedRemoteCoOpPreferences(_ body: () -> Void) {
        preferenceDomainTestLock.lock()
        defer { preferenceDomainTestLock.unlock() }
        let keys = [enabledKey, reservedGuestSlotsKey, latencyModeKey, lowLatencyDefaultMigrationVersionKey, hostedGuestPageURLKey]
        let defaults = UserDefaults.standard
        let previousValues = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in previousValues {
                if let value {
                    defaults.set(value, forKey: key)
                    var domain = defaults.persistentDomain(forName: preferenceDomain) ?? [:]
                    domain[key] = value
                    defaults.setPersistentDomain(domain, forName: preferenceDomain)
                } else {
                    removePreferenceValue(key)
                }
            }
            defaults.synchronize()
        }
        body()
    }

    static func setPreferenceValue(_ value: Any, forKey key: String) {
        preferenceDomainTestLock.lock()
        defer { preferenceDomainTestLock.unlock() }
        let defaults = UserDefaults.standard
        defaults.set(value, forKey: key)
        var domain = defaults.persistentDomain(forName: preferenceDomain) ?? [:]
        domain[key] = value
        defaults.setPersistentDomain(domain, forName: preferenceDomain)
        defaults.synchronize()
    }

    static func removePreferenceValue(_ key: String) {
        preferenceDomainTestLock.lock()
        defer { preferenceDomainTestLock.unlock() }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: key)
        var domain = defaults.persistentDomain(forName: preferenceDomain) ?? [:]
        domain.removeValue(forKey: key)
        defaults.setPersistentDomain(domain, forName: preferenceDomain)
        defaults.synchronize()
    }

    static func makeVideoFrame() throws -> RTCVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        #expect(status == kCVReturnSuccess)
        let buffer = RTCCVPixelBuffer(pixelBuffer: try #require(pixelBuffer))
        return RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 1)
    }

    static func makeAudioFrame() -> OPNRemoteCoOpHostAudioFrame {
        OPNRemoteCoOpHostAudioFrame(samples: audioData([1, -1]), frameCount: 1)
    }

    static func audioData(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { buffer -> Data in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Int16>.size)
        }
    }
}
